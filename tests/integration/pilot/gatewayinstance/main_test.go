//go:build integ
// +build integ

// Copyright Istio Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package gatewayinstance

import (
	"context"
	"fmt"
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"istio.io/istio/pkg/config/protocol"
	"istio.io/istio/pkg/http/headers"
	"istio.io/istio/pkg/test/echo/common/scheme"
	"istio.io/istio/pkg/test/framework"
	"istio.io/istio/pkg/test/framework/components/crd"
	"istio.io/istio/pkg/test/framework/components/echo"
	"istio.io/istio/pkg/test/framework/components/echo/check"
	"istio.io/istio/pkg/test/framework/components/echo/common/deployment"
	"istio.io/istio/pkg/test/framework/components/istio"
	"istio.io/istio/pkg/test/framework/components/namespace"
	"istio.io/istio/pkg/test/framework/label"
	"istio.io/istio/pkg/test/framework/resource"
)

var (
	// Istio System Namespaces
	gatewayInstanceNS namespace.Instance
	meshInstanceNS    namespace.Instance

	// Application Namespaces.
	echoNS     namespace.Instance
	externalNS namespace.Instance
	apps       deployment.SingleNamespaceView
)

// TestMain defines the entrypoint for multiple controlplane tests using revisions and discoverySelectors.
func TestMain(m *testing.M) {
	// nolint: staticcheck
	framework.
		NewSuite(m).
		// Requires two CPs with specific names to be configured.
		Label(label.CustomSetup).
		SetupParallel(
			namespace.Setup(&gatewayInstanceNS, namespace.Config{Prefix: "gateway", Labels: map[string]string{"istio-instance": "gateway"}}),
			namespace.Setup(&meshInstanceNS, namespace.Config{Prefix: "mesh", Labels: map[string]string{"istio-instance": "mesh"}})).
		Setup(istio.Setup(nil, func(ctx resource.Context, cfg *istio.Config) {
			s := ctx.Settings()
			// TODO test framework has to be enhanced to use istioNamespace in istioctl commands used for VM config
			s.SkipWorkloadClasses = append(s.SkipWorkloadClasses, echo.VM)
			s.DisableDefaultExternalServiceConnectivity = true
			// disable CNI. If we enable it, we do it only in the mesh instance
			cfg.EnableCNI = false
			cfg.Values["global.istioNamespace"] = gatewayInstanceNS.Name()
			cfg.SystemNamespace = gatewayInstanceNS.Name()
			cfg.ControlPlaneValues = fmt.Sprintf(`
namespace: %s
revision: gateway
components:
  ingressGateways:
    - name: istio-ingressgateway
      enabled: false
  egressGateways:
    - name: istio-egressgateway
      enabled: false
values:
  pilot:
    env:
      PILOT_GATEWAY_API_DEFAULT_GATEWAYCLASS_NAME: "gw-provider"
      PILOT_GATEWAY_API_CONTROLLER_NAME: "gw-provider.io/controller"
      PILOT_ENABLE_GATEWAY_API_CA_CERT_ONLY: "true"
  global:
    trustBundleName: gateway-root-cert
    istioNamespace: %s`,
				gatewayInstanceNS.Name(), gatewayInstanceNS.Name())
			cfg.DeployEastWestGW = false
		})).
		Setup(istio.Setup(nil, func(ctx resource.Context, cfg *istio.Config) {
			s := ctx.Settings()
			// TODO test framework has to be enhanced to use istioNamespace in istioctl commands used for VM config
			s.SkipWorkloadClasses = append(s.SkipWorkloadClasses, echo.VM)

			cfg.Values["global.istioNamespace"] = meshInstanceNS.Name()
			cfg.SystemNamespace = meshInstanceNS.Name()
			cfg.ControlPlaneValues = fmt.Sprintf(`
namespace: %s
revision: mesh`, meshInstanceNS.Name())
		})).
		SetupParallel(
			// application namespaces are labeled according to the required control plane ownership.
			namespace.Setup(&echoNS, namespace.Config{Prefix: "echo1", Inject: true, Revision: "mesh", Labels: nil}),
			namespace.Setup(&externalNS, namespace.Config{Prefix: "external", Inject: false})).
		SetupParallel(
			deployment.SetupSingleNamespace(&apps, deployment.Config{
				Namespaces: []namespace.Getter{
					namespace.Future(&echoNS),
				},
				ExternalNamespace: namespace.Future(&externalNS),
			})).
		Run()
}

func deployGatewayOrFail(t framework.TestContext) {
	t.ConfigIstio().YAML(externalNS.Name(), `apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: gateway
  labels:
    istio.io/rev: gateway
spec:
  gatewayClassName: gw-provider
  listeners:
  - name: default
    hostname: "*.example.com"
    port: 80
    protocol: HTTP
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: external
spec:
  parentRefs:
  - name: gateway
  hostnames: ["external.example.com"]
  rules:
  - backendRefs:
    - name: external
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: internal
spec:
  parentRefs:
  - name: gateway
  hostnames: ["*.internal.example.com"]
  rules:
  - backendRefs:
    - name: istio-ingressgateway.`+meshInstanceNS.Name()+`
      port: 80
`).ApplyOrFail(t)

	t.ConfigIstio().YAML(meshInstanceNS.Name(), `apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: refgrant
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: `+externalNS.Name()+`
  to:
  - group: ""
    kind: Service
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: echo-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*.internal.example.com"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: b-vs
spec:
  hosts:
  - b.internal.example.com
  gateways:
  - echo-gateway
  http:
  - route:
    - destination:
        host: `+apps.B.ClusterLocalFQDN()+`
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: c-vs
spec:
  hosts:
  - c.internal.example.com
  gateways:
  - echo-gateway
  http:
  - route:
    - destination:
        host: `+apps.C.ClusterLocalFQDN()+`
`).ApplyOrFail(t)
}

func TestGatewayInstance(t *testing.T) {
	framework.NewTest(t).
		Run(func(t framework.TestContext) {
			crd.DeployGatewayAPIOrSkip(t)
			deployGatewayOrFail(t)
			t.NewSubTest("external").Run(ExternalServiceTest)
			t.NewSubTest("mesh").Run(MeshServiceTest)
			t.NewSubTest("cabundle").Run(CABundleInjectionTest)
		})
}

func ExternalServiceTest(t framework.TestContext) {
	testCases := []struct {
		check echo.Checker
		from  echo.Instances
		host  string
	}{
		{
			check: check.OK(),
			from:  apps.B,
			host:  "external.example.com",
		},
		{
			check: check.NotOK(),
			from:  apps.B,
			host:  "bar",
		},
	}
	for _, tc := range testCases {
		t.NewSubTest(fmt.Sprintf("gateway-connectivity-from-%s", tc.from[0].NamespacedName())).Run(func(t framework.TestContext) {
			tc.from[0].CallOrFail(t, echo.CallOptions{
				Port: echo.Port{
					Protocol:    protocol.HTTP,
					ServicePort: 80,
				},
				Scheme: scheme.HTTP,
				HTTP: echo.HTTP{
					Headers: headers.New().WithHost(tc.host).Build(),
				},
				Address: fmt.Sprintf("gateway-gw-provider.%s.svc.cluster.local", externalNS.Name()),
				Check:   tc.check,
			})
		})
	}
}

func MeshServiceTest(t framework.TestContext) {
	testCases := []struct {
		check echo.Checker
		from  echo.Instances
		host  string
	}{
		{
			check: check.OK(),
			from:  apps.External.All,
			host:  "b.internal.example.com",
		},
		{
			check: check.OK(),
			from:  apps.External.All,
			host:  "c.internal.example.com",
		},
		{
			check: check.NotOK(),
			from:  apps.B,
			host:  "bar",
		},
	}
	for _, tc := range testCases {
		t.NewSubTest(fmt.Sprintf("gateway-connectivity-from-%s", tc.from[0].NamespacedName())).Run(func(t framework.TestContext) {
			tc.from[0].CallOrFail(t, echo.CallOptions{
				Port: echo.Port{
					Protocol:    protocol.HTTP,
					ServicePort: 80,
				},
				Scheme: scheme.HTTP,
				HTTP: echo.HTTP{
					Headers: headers.New().WithHost(tc.host).Build(),
				},
				Address: fmt.Sprintf("istio-ingressgateway.%s.svc.cluster.local", meshInstanceNS.Name()),
				Check:   tc.check,
			})
		})
	}
}

func CABundleInjectionTest(t framework.TestContext) {
	testCases := []struct {
		shouldExist  bool
		namespace    namespace.Instance
		caBundleName string
	}{
		{
			shouldExist:  true,
			namespace:    externalNS,
			caBundleName: "gateway-root-cert",
		},
		{
			shouldExist:  false,
			namespace:    echoNS,
			caBundleName: "gateway-root-cert",
		},
		{
			shouldExist:  true,
			namespace:    echoNS,
			caBundleName: "istio-ca-root-cert",
		},
		{
			shouldExist:  true,
			namespace:    meshInstanceNS,
			caBundleName: "istio-ca-root-cert",
		},
		{
			shouldExist:  false,
			namespace:    meshInstanceNS,
			caBundleName: "gateway-root-cert",
		},
	}
	for _, tc := range testCases {
		t.NewSubTest(fmt.Sprintf("gateway-ca-injected-in-namespace-%s-%v", tc.namespace.Name(), tc.shouldExist)).Run(func(t framework.TestContext) {
			for _, c := range t.Clusters() {
				_, err := c.Kube().CoreV1().ConfigMaps(tc.namespace.Name()).Get(context.TODO(), tc.caBundleName, v1.GetOptions{})
				if tc.shouldExist && err != nil {
					t.Errorf("%s should exist in %s. unexpected error: %v", tc.caBundleName, tc.namespace.Name(), err)
				} else if !tc.shouldExist && !apierrors.IsNotFound(err) {
					t.Errorf("%s should not exist in %s. unexpected error: %v", tc.caBundleName, tc.namespace.Name(), err)
				}
			}
		})
	}
}

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

package gateway

import (
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/types"
	utilerrors "k8s.io/apimachinery/pkg/util/errors"
	gateway "sigs.k8s.io/gateway-api/apis/v1beta1"

	"istio.io/api/label"
	"istio.io/istio/pilot/pkg/features"
	"istio.io/istio/pilot/pkg/keycertbundle"
	"istio.io/istio/pkg/config/constants"
	"istio.io/istio/pkg/kube"
	"istio.io/istio/pkg/kube/controllers"
	"istio.io/istio/pkg/kube/kclient"
	"istio.io/istio/security/pkg/k8s"
)

const (
	// maxRetries is the number of times a gateway will be retried before it is dropped out of the queue.
	// With the current rate-limiter in use (5ms*2^(maxRetries-1)) the following numbers represent the
	// sequence of delays between successive queuing of a gateway.
	//
	// 5ms, 10ms, 20ms, 40ms, 80ms
	maxRetries = 5

	// CRLNamespaceConfigMap is the name of the ConfigMap in each namespace storing the CRL of plugged in CA certificates.
	CRLNamespaceConfigMap = "istio-ca-crl"
)

var (
	// CACertNamespaceConfigMap is the name of the ConfigMap in each namespace storing the root cert of non-Kube CA.
	CACertNamespaceConfigMap = features.CACertConfigMapName

	configMapLabel = map[string]string{"istio.io/config": "true", "openshift.io/mesh": "true"}
)

// GatewayCAController manages reconciles a configmap in each namespace with a desired set of data.
type GatewayCAController struct {
	caBundleWatcher *keycertbundle.Watcher

	queue controllers.Queue

	gateways      kclient.Client[*gateway.Gateway]
	configmaps    kclient.Client[*v1.ConfigMap]
	crlConfigmaps kclient.Client[*v1.ConfigMap]
}

// NewGatewayCAController returns a pointer to a newly constructed GatewayCAController instance.
func NewGatewayCAController(kubeClient kube.Client, caBundleWatcher *keycertbundle.Watcher, revision string) *GatewayCAController {
	c := &GatewayCAController{
		caBundleWatcher: caBundleWatcher,
	}
	c.queue = controllers.NewQueue("gateway ca controller",
		controllers.WithReconciler(c.reconcileCACertAndCRL),
		controllers.WithMaxAttempts(maxRetries))

	c.configmaps = kclient.NewFiltered[*v1.ConfigMap](kubeClient, kclient.Filter{
		FieldSelector: "metadata.name=" + CACertNamespaceConfigMap,
		ObjectFilter:  kubeClient.ObjectFilter(),
	})
	c.gateways = kclient.NewFiltered[*gateway.Gateway](kubeClient, kclient.Filter{
		ObjectFilter: kubeClient.ObjectFilter(),
	})
	c.configmaps.AddEventHandler(controllers.ObjectHandler(c.queue.AddObject))

	c.gateways.AddEventHandler(controllers.FilteredObjectSpecHandler(c.queue.AddObject, func(o controllers.Object) bool {
		return o.GetLabels()[label.IoIstioRev.Name] == revision
	}))

	if features.EnableCACRL {
		// set filtered client for crl configmap
		c.crlConfigmaps = kclient.NewFiltered[*v1.ConfigMap](kubeClient, kclient.Filter{
			FieldSelector: "metadata.name=" + CRLNamespaceConfigMap,
			ObjectFilter:  kubeClient.ObjectFilter(),
		})

		// register crl configmap event handler
		c.crlConfigmaps.AddEventHandler(controllers.ObjectHandler(c.queue.AddObject))
	}

	return c
}

// Run starts the GatewayCAController until a value is sent to stopCh.
func (gwc *GatewayCAController) Run(stopCh <-chan struct{}) {
	if gwc.crlConfigmaps != nil {
		if !kube.WaitForCacheSync("gateway ca controller", stopCh, gwc.gateways.HasSynced, gwc.configmaps.HasSynced, gwc.crlConfigmaps.HasSynced) {
			gwc.queue.ShutDownEarly()
			return
		}
	} else {
		if !kube.WaitForCacheSync("gateway ca controller", stopCh, gwc.gateways.HasSynced, gwc.configmaps.HasSynced) {
			gwc.queue.ShutDownEarly()
			return
		}
	}

	go gwc.startCaBundleWatcher(stopCh)
	gwc.queue.Run(stopCh)
	if gwc.crlConfigmaps != nil {
		controllers.ShutdownAll(gwc.configmaps, gwc.gateways, gwc.crlConfigmaps)
	} else {
		controllers.ShutdownAll(gwc.configmaps, gwc.gateways)
	}
}

// startCaBundleWatcher listens for updates to the CA bundle and update cm in each namespace
func (gwc *GatewayCAController) startCaBundleWatcher(stop <-chan struct{}) {
	id, watchCh := gwc.caBundleWatcher.AddWatcher()
	defer gwc.caBundleWatcher.RemoveWatcher(id)
	for {
		select {
		case <-watchCh:
			for _, gw := range gwc.gateways.List("", labels.Everything()) {
				gwc.gatewayChange(gw)
			}
		case <-stop:
			return
		}
	}
}

// reconcileCACertAndCRL will reconcile the ca root cert and crl configmap for the specified namespace
// If the configmap is not found, it will be created.
func (gwc *GatewayCAController) reconcileCACertAndCRL(o types.NamespacedName) error {
	errs := []error{
		// upsert root-cert configmap
		k8s.InsertDataToConfigMap(
			gwc.configmaps,
			metav1.ObjectMeta{
				Name:      CACertNamespaceConfigMap,
				Namespace: o.Namespace,
				Labels:    configMapLabel,
			},
			constants.CACertNamespaceConfigMapDataName,
			gwc.caBundleWatcher.GetCABundle(),
		),
	}

	if features.EnableCACRL {
		// upsert crl configmap
		errs = append(
			errs,
			k8s.InsertDataToConfigMap(
				gwc.crlConfigmaps,
				metav1.ObjectMeta{
					Name:      CRLNamespaceConfigMap,
					Namespace: o.Namespace,
					Labels:    configMapLabel,
				},
				constants.CACRLNamespaceConfigMapDataName,
				gwc.caBundleWatcher.GetCRL(),
			),
		)
	}

	// Returns nil when there are no errors,
	// the single error when there is exactly one,
	// or a combined error when there are several.
	return utilerrors.NewAggregate(errs)
}

// On gateway change, update the config map.
// If terminating, this will be skipped
func (gwc *GatewayCAController) gatewayChange(gw *gateway.Gateway) {
	if gw.DeletionTimestamp == nil {
		gwc.syncGateway(gw.Name, gw.Namespace)
	}
}

func (gwc *GatewayCAController) syncGateway(name, namespace string) {
	gwc.queue.Add(types.NamespacedName{Name: name, Namespace: namespace})
}

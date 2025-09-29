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
	"context"
	"fmt"
	"reflect"
	"testing"
	"time"

	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	gateway "sigs.k8s.io/gateway-api/apis/v1beta1"
	gatewayapiclient "sigs.k8s.io/gateway-api/pkg/client/clientset/versioned"

	"istio.io/api/label"
	"istio.io/istio/pilot/pkg/keycertbundle"
	"istio.io/istio/pkg/config/constants"
	"istio.io/istio/pkg/kube"
	"istio.io/istio/pkg/kube/kclient"
	"istio.io/istio/pkg/test"
	"istio.io/istio/pkg/test/util/retry"
)

const (
	TestRevision = "test"
)

func TestNamespaceControllerWithSameRevision(t *testing.T) {
	client := kube.NewFakeClient()
	t.Cleanup(client.Shutdown)
	watcher := keycertbundle.NewWatcher()
	caBundle := []byte("caBundle")
	watcher.SetAndNotify(nil, nil, caBundle)
	stop := test.NewStop(t)

	nc := NewGatewayCAController(client, watcher, TestRevision)
	client.RunAndWait(stop)
	go nc.Run(stop)
	retry.UntilOrFail(t, nc.queue.HasSynced)

	expectedData := map[string]string{
		constants.CACertNamespaceConfigMapDataName: string(caBundle),
	}
	createGateway(t, client.GatewayAPI(), "bar", "foo", map[string]string{label.IoIstioRev.Name: TestRevision})
	expectConfigMap(t, nc.configmaps, CACertNamespaceConfigMap, "foo", expectedData)

	// Make sure random configmap does not get updated
	cmData := createConfigMap(t, client.Kube(), "not-root", "foo", "k")
	expectConfigMap(t, nc.configmaps, "not-root", "foo", cmData)

	newCaBundle := []byte("caBundle-new")
	watcher.SetAndNotify(nil, nil, newCaBundle)
	newData := map[string]string{
		constants.CACertNamespaceConfigMapDataName: string(newCaBundle),
	}
	expectConfigMap(t, nc.configmaps, CACertNamespaceConfigMap, "foo", newData)

	deleteConfigMap(t, client.Kube(), "foo")
	expectConfigMap(t, nc.configmaps, CACertNamespaceConfigMap, "foo", newData)
}

func TestNamespaceControllerWithOtherRevision(t *testing.T) {
	client := kube.NewFakeClient()
	t.Cleanup(client.Shutdown)
	watcher := keycertbundle.NewWatcher()
	caBundle := []byte("caBundle")
	watcher.SetAndNotify(nil, nil, caBundle)
	stop := test.NewStop(t)

	nc := NewGatewayCAController(client, watcher, TestRevision)
	client.RunAndWait(stop)
	go nc.Run(stop)
	retry.UntilOrFail(t, nc.queue.HasSynced)

	createGateway(t, client.GatewayAPI(), "bar", "foo", map[string]string{label.IoIstioRev.Name: "other-revision"})
	expectConfigMapNotExist(t, nc.configmaps, "foo")
}

func deleteConfigMap(t *testing.T, client kubernetes.Interface, ns string) {
	t.Helper()
	_, err := client.CoreV1().ConfigMaps(ns).Get(context.TODO(), CACertNamespaceConfigMap, metav1.GetOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if err := client.CoreV1().ConfigMaps(ns).Delete(context.TODO(), CACertNamespaceConfigMap, metav1.DeleteOptions{}); err != nil {
		t.Fatal(err)
	}
}

func createConfigMap(t *testing.T, client kubernetes.Interface, name, ns, key string) map[string]string {
	t.Helper()
	data := map[string]string{key: "v"}
	_, err := client.CoreV1().ConfigMaps(ns).Create(context.Background(), &v1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ns,
		},
		Data: data,
	}, metav1.CreateOptions{})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func createGateway(t *testing.T, client gatewayapiclient.Interface, n, ns string, labels map[string]string) {
	t.Helper()
	if _, err := client.GatewayV1beta1().Gateways(ns).Create(context.TODO(), &gateway.Gateway{
		ObjectMeta: metav1.ObjectMeta{Name: n, Labels: labels},
	}, metav1.CreateOptions{}); err != nil {
		t.Fatal(err)
	}
}

// nolint:unparam
func expectConfigMap(t *testing.T, configmaps kclient.Client[*v1.ConfigMap], name, ns string, data map[string]string) {
	t.Helper()
	retry.UntilSuccessOrFail(t, func() error {
		cm := configmaps.Get(name, ns)
		if cm == nil {
			return fmt.Errorf("not found")
		}
		if !reflect.DeepEqual(cm.Data, data) {
			return fmt.Errorf("data mismatch, expected %+v got %+v", data, cm.Data)
		}
		return nil
	}, retry.Timeout(time.Second*10))
}

func expectConfigMapNotExist(t *testing.T, configmaps kclient.Client[*v1.ConfigMap], ns string) {
	t.Helper()
	err := retry.Until(func() bool {
		cm := configmaps.Get(CACertNamespaceConfigMap, ns)
		return cm != nil
	}, retry.Timeout(time.Millisecond*25))

	if err == nil {
		t.Fatalf("%s namespace should not have %s configmap.", ns, CACertNamespaceConfigMap)
	}
}

func TestGatewayCAControllerForCrlConfigMap(t *testing.T) {
	client := kube.NewFakeClient()
	t.Cleanup(client.Shutdown)
	watcher := keycertbundle.NewWatcher()
	crlData := []byte("crl")
	watcher.SetAndNotifyCACRL(crlData)
	stop := test.NewStop(t)

	nc := NewGatewayCAController(client, watcher, TestRevision)
	client.RunAndWait(stop)
	go nc.Run(stop)
	retry.UntilOrFail(t, nc.queue.HasSynced)

	expectedData := map[string]string{
		constants.CACRLNamespaceConfigMapDataName: string(crlData),
	}
	createGateway(t, client.GatewayAPI(), "bar", "foo", map[string]string{label.IoIstioRev.Name: TestRevision})
	expectConfigMap(t, nc.crlConfigmaps, CRLNamespaceConfigMap, "foo", expectedData)

	// Make sure random configmap does not interfere
	createConfigMap(t, client.Kube(), "not-crl-cm", "foo", "key")

	newCrlData := []byte("new-crl")
	watcher.SetAndNotifyCACRL(newCrlData)
	newData := map[string]string{
		constants.CACRLNamespaceConfigMapDataName: string(newCrlData),
	}
	expectConfigMap(t, nc.crlConfigmaps, CRLNamespaceConfigMap, "foo", newData)

	deleteCrlConfigMap(t, client.Kube(), "foo")
	expectConfigMap(t, nc.crlConfigmaps, CRLNamespaceConfigMap, "foo", newData)
}

func deleteCrlConfigMap(t *testing.T, client kubernetes.Interface, ns string) {
	t.Helper()
	_, err := client.CoreV1().ConfigMaps(ns).Get(context.TODO(), CRLNamespaceConfigMap, metav1.GetOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if err := client.CoreV1().ConfigMaps(ns).Delete(context.TODO(), CRLNamespaceConfigMap, metav1.DeleteOptions{}); err != nil {
		t.Fatal(err)
	}
}

# Quantum-Safe Gateway

## Prerequisites

1. Install OpenShift Service Mesh Operator 3.1+.
1. Install Gateway API CRDs (not required on OCP 4.19+).

   ```shell
   oc apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
   ```

## Customize istio-proxy image

OpenShift Service Mesh 3.1 does not deliver istio-proxy image with built-in support for PQC.
Enabling post-quantum safe algorithms requires configuring [OQS provider](https://github.com/open-quantum-safe/oqs-provider) in the proxy container.

1. Get pull secret from OCP and build the proxy image with OQS provider:

    ```shell
    oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/config.json
    podman --config /tmp build -t localhost:5000/istio-system/istio-proxyv2-rhel9-oqs:1.26.2 .
    ```

1. Configure permissions for pushing images to OCP image registry:

   ```shell
   oc new-project istio-system
   oc policy add-role-to-user system:image-pusher -z default -n istio-system
   TOKEN=$(oc create token default -n istio-system)
   ```

1. Create an image stream for custom istio-proxy and expose the registry:

   ```shell
   oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"defaultRoute":true}}'
   oc create imagestream istio-proxyv2-rhel9-oqs -n istio-system
   ```

1. Push the local image:

   ```shell
   HOST=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
   podman login --tls-verify=false -u default -p $TOKEN $HOST
   podman push --tls-verify=false istio-proxyv2-rhel9-oqs:1.26.2 $HOST/istio-system/istio-proxyv2-rhel9-oqs:1.26.2
   ```

## Install Service Mesh

1. Install CNI:

   ```shell
   oc new-project istio-cni
   oc apply -f - <<EOF
   apiVersion: sailoperator.io/v1
   kind: IstioCNI
   metadata:
     name: default
   spec:
     version: v1.26.2
     namespace: istio-cni
   EOF
   ```

1. Install control plane:

   ```shell
   oc apply -f - <<EOF
   apiVersion: sailoperator.io/v1
   kind: Istio
   metadata:
     name: default
   spec:
     version: v1.26.2
     namespace: istio-system
     updateStrategy:
       type: InPlace
     values:
       meshConfig:
         accessLogFile: /dev/stdout
         tlsDefaults:
           ecdhCurves:
           - X25519MLKEM768
   EOF
   ```

1. Generate certificates:

    ```shell
    mkdir certs
    openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -subj '/O=example Inc./CN=example.com' -keyout certs/example.com.key -out certs/example.com.crt
    openssl req -out certs/httpbin.example.com.csr -newkey rsa:2048 -nodes -keyout certs/httpbin.example.com.key -subj "/CN=httpbin.example.com/O=httpbin organization"
    openssl x509 -req -sha256 -days 365 -CA certs/example.com.crt -CAkey certs/example.com.key -set_serial 0 -in certs/httpbin.example.com.csr -out certs/httpbin.example.com.crt
    openssl req -out certs/helloworld.example.com.csr -newkey rsa:2048 -nodes -keyout certs/helloworld.example.com.key -subj "/CN=helloworld.example.com/O=helloworld organization"
    openssl x509 -req -sha256 -days 365 -CA certs/example.com.crt -CAkey certs/example.com.key -set_serial 1 -in certs/helloworld.example.com.csr -out certs/helloworld.example.com.crt
    ```

1. Create a secret for a gateway:

    ```shell
    oc create -n istio-system secret tls httpbin-credential \
        --key=certs/httpbin.example.com.key \
        --cert=certs/httpbin.example.com.crt
    ```

1. Deploy a Gateway:

   ```shell
   oc apply -f - <<EOF
   apiVersion: gateway.networking.k8s.io/v1beta1
   kind: Gateway
   metadata:
     name: pqc-gateway
     namespace: istio-system
     annotations:
       sidecar.istio.io/proxyImage: "image-registry.openshift-image-registry.svc:5000/istio-system/istio-proxyv2-rhel9-oqs:1.26.2"
   spec:
     gatewayClassName: istio
     listeners:
     - name: https
       port: 443
       protocol: HTTPS
       tls:
         mode: Terminate
         certificateRefs:
         - name: httpbin-credential
           namespace: istio-system
       allowedRoutes:
         namespaces:
           from: All
   ---
   apiVersion: gateway.networking.k8s.io/v1beta1
   kind: HTTPRoute
   metadata:
     name: httpbin-route
     namespace: default
   spec:
     parentRefs:
     - name: pqc-gateway
       namespace: istio-system
     hostnames:
     - "httpbin.example.com"
     rules:
     - matches:
       - path:
           type: PathPrefix
           value: /
       backendRefs:
       - name: httpbin
         port: 8000
   EOF
   ```

1. Deploy the backend server:

   ```shell
   oc label ns default istio-injection=enabled
   oc apply -n default -f https://raw.githubusercontent.com/openshift-service-mesh/istio/master/samples/httpbin/httpbin.yaml
   ```

## Verification steps

1. Connect to the gateway with PQC-enabled client using `X25519MLKEM768` for key exchange - it should succeed:

   ```shell
   INGRESS_ADDR=$(kubectl get svc pqc-gateway-istio -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   ```
   ```shell
   podman run --rm -it \
     -v ./certs/example.com.crt:/etc/certs/example.com.crt \
     docker.io/openquantumsafe/curl \
     curl -vk "https://$INGRESS_ADDR:443/headers" \
     -H "Host: httpbin.example.com" \
     --curves X25519MLKEM768 \
     --cacert /etc/certs/example.com.crt
   ```

1. Connect to the gateway with `curl` without any PQC-specific algorithms - it should fail:

   ```shell
   curl -vk "https://$INGRESS_ADDR:443/headers" \
     -H "Host: httpbin.example.com" \
     --cacert ./certs/example.com.crt
   ```
   ```text
   * TLSv1.3 (OUT), TLS handshake, Client hello (1):
   * TLSv1.3 (IN), TLS alert, handshake failure (552):
   * TLS connect error: error:0A000410:SSL routines::ssl/tls alert handshake failure
   * closing connection #0
   curl: (35) TLS connect error: error:0A000410:SSL routines::ssl/tls alert handshake failure
   ```

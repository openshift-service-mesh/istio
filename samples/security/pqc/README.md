# OSSM 3 - PQC demo

## Prerequisites

1. Install OpenShift Service Mesh Operator 3.1.
2. Install Gateway API CRDs.

## Customize proxy image

1. Get pull secret from OCP:

    ```shell
    oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/config.json
    ```

1. Pull istio-proxy 1.26.2:

    ```shell
    docker --config /tmp pull registry.redhat.io/openshift-service-mesh/istio-proxyv2-rhel9@sha256:d518f3d1539f45e1253c5c9fa22062802804601d4998cd50344e476a3cc388fe
    ```

1. Build a custom proxy with OQS provider:

    ```shell
    docker build -t localhost:5000/istio-system/istio-proxy-oqs:1.26.2 .
    ```

1. Expose cluster registry to your local environment:

    ```shell
    oc port-forward -n openshift-image-registry svc/image-registry 5000:5000 &
    ```

1. Obtain a token from https://oauth-openshift.<your-cluster-domain>/oauth/token/request and login to the cluster registry:

    ```shell
    docker login -u kubeadmin localhost:5000
    ```

1. Alternatively, you can upload the image with the following command:

    ```shell
    docker login -u $(oc whoami) -p $(oc whoami -t) localhost:5000
    ```

1. Push the OQS-based proxy:

    ```shell
    oc new-project istio-system
    docker push localhost:5000/istio-system/istio-proxy-oqs:1.26.2
    ```

1. Stop port-forwarding the registry API:

    ```shell
    kill %1
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
    mkdir example_certs1
    openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -subj '/O=example Inc./CN=example.com' -keyout example_certs1/example.com.key -out example_certs1/example.com.crt
    openssl req -out example_certs1/httpbin.example.com.csr -newkey rsa:2048 -nodes -keyout example_certs1/httpbin.example.com.key -subj "/CN=httpbin.example.com/O=httpbin organization"
    openssl x509 -req -sha256 -days 365 -CA example_certs1/example.com.crt -CAkey example_certs1/example.com.key -set_serial 0 -in example_certs1/httpbin.example.com.csr -out example_certs1/httpbin.example.com.crt
    openssl req -out example_certs1/helloworld.example.com.csr -newkey rsa:2048 -nodes -keyout example_certs1/helloworld.example.com.key -subj "/CN=helloworld.example.com/O=helloworld organization"
    openssl x509 -req -sha256 -days 365 -CA example_certs1/example.com.crt -CAkey example_certs1/example.com.key -set_serial 1 -in example_certs1/helloworld.example.com.csr -out example_certs1/helloworld.example.com.crt
    ```

1. Create a secret for a gateway:

    ```shell
    oc create -n istio-system secret tls httpbin-credential \
        --key=example_certs1/httpbin.example.com.key \
        --cert=example_certs1/httpbin.example.com.crt
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
       sidecar.istio.io/proxyImage: "image-registry.openshift-image-registry.svc:5000/istio-system/istio-proxy-oqs:1.26.2"
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

1. Deploy httpbin:

   ```shell
   oc label ns default istio-injection=enabled
   oc apply -n default -f https://raw.githubusercontent.com/openshift-service-mesh/istio/master/samples/httpbin/httpbin.yaml
   ```

1. Send a test request using PQC key exchange algorithm:

   ```shell
   INGRESS_ADDR=$(kubectl get svc pqc-gateway-istio -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   docker run \
     --network kind \
     -v ./example_certs1/example.com.crt:/etc/example_certs1/example.com.crt \
     --rm -it openquantumsafe/curl \
     curl -vk \
     --curves X25519MLKEM768 \
     --cacert /etc/example_certs1/example.com.crt \
     -H "Host: httpbin.example.com" \
     "https://$INGRESS_ADDR:443/status/200"
   ```


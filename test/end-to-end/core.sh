#!/bin/bash

# This script tests the high level end-to-end functionality demonstrated
# as part of the examples/sample-app

set -o errexit
set -o nounset
set -o pipefail

OS_ROOT=$(dirname "${BASH_SOURCE}")/../..
source "${OS_ROOT}/hack/util.sh"
os::log::install_errexit

ROUTER_TESTS_ENABLED="${ROUTER_TESTS_ENABLED:-true}"
TEST_ASSETS="${TEST_ASSETS:-false}"


function wait_for_app() {
  echo "[INFO] Waiting for app in namespace $1"
  echo "[INFO] Waiting for database pod to start"
  wait_for_command "oc get -n $1 pods -l name=database | grep -i Running" $((60*TIME_SEC))
  oc logs dc/database -n $1 --follow

  echo "[INFO] Waiting for database service to start"
  wait_for_command "oc get -n $1 services | grep database" $((20*TIME_SEC))
  DB_IP=$(oc get -n $1 --output-version=v1beta3 --template="{{ .spec.portalIP }}" service database)

  echo "[INFO] Waiting for frontend pod to start"
  wait_for_command "oc get -n $1 pods | grep frontend | grep -i Running" $((120*TIME_SEC))
  oc logs dc/frontend -n $1 --follow

  echo "[INFO] Waiting for frontend service to start"
  wait_for_command "oc get -n $1 services | grep frontend" $((20*TIME_SEC))
  FRONTEND_IP=$(oc get -n $1 --output-version=v1beta3 --template="{{ .spec.portalIP }}" service frontend)

  echo "[INFO] Waiting for database to start..."
  wait_for_url_timed "http://${DB_IP}:5434" "[INFO] Database says: " $((3*TIME_MIN))

  echo "[INFO] Waiting for app to start..."
  wait_for_url_timed "http://${FRONTEND_IP}:5432" "[INFO] Frontend says: " $((2*TIME_MIN))

  echo "[INFO] Testing app"
  wait_for_command '[[ "$(curl -s -X POST http://${FRONTEND_IP}:5432/keys/foo -d value=1337)" = "Key created" ]]'
  wait_for_command '[[ "$(curl -s http://${FRONTEND_IP}:5432/keys/foo)" = "1337" ]]'
}

# service dns entry is visible via master service
# find the IP of the master service by asking the API_HOST to verify DNS is running there
MASTER_SERVICE_IP="$(dig @${API_HOST} "kubernetes.default.svc.cluster.local." +short A | head -n 1)"
# find the IP of the master service again by asking the IP of the master service, to verify port 53 tcp/udp is routed by the service
[ "$(dig +tcp @${MASTER_SERVICE_IP} "kubernetes.default.svc.cluster.local." +short A | head -n 1)" == "${MASTER_SERVICE_IP}" ]
[ "$(dig +notcp @${MASTER_SERVICE_IP} "kubernetes.default.svc.cluster.local." +short A | head -n 1)" == "${MASTER_SERVICE_IP}" ]

# add e2e-user as a viewer for the default namespace so we can see infrastructure pieces appear
openshift admin policy add-role-to-user view e2e-user --namespace=default

# pre-load some image streams and templates
oc create -f examples/image-streams/image-streams-centos7.json --namespace=openshift
oc create -f examples/sample-app/application-template-stibuild.json --namespace=openshift
oc create -f examples/jenkins/application-template.json --namespace=openshift
oc create -f examples/db-templates/mongodb-ephemeral-template.json --namespace=openshift
oc create -f examples/db-templates/mysql-ephemeral-template.json --namespace=openshift
oc create -f examples/db-templates/postgresql-ephemeral-template.json --namespace=openshift

# create test project so that this shows up in the console
openshift admin new-project test --description="This is an example project to demonstrate OpenShift v3" --admin="e2e-user"
openshift admin new-project docker --description="This is an example project to demonstrate OpenShift v3" --admin="e2e-user"
openshift admin new-project custom --description="This is an example project to demonstrate OpenShift v3" --admin="e2e-user"
openshift admin new-project cache --description="This is an example project to demonstrate OpenShift v3" --admin="e2e-user"

echo "The console should be available at ${API_SCHEME}://${PUBLIC_MASTER_HOST}:${API_PORT}/console."
echo "Log in as 'e2e-user' to see the 'test' project."

install_router
install_registry

echo "[INFO] Pre-pulling and pushing ruby-22-centos7"
docker pull centos/ruby-22-centos7:latest
echo "[INFO] Pulled ruby-22-centos7"

echo "[INFO] Waiting for Docker registry pod to start"
wait_for_registry

# services can end up on any IP.  Make sure we get the IP we need for the docker registry
DOCKER_REGISTRY=$(oc get --output-version=v1beta3 --template="{{ .spec.portalIP }}:{{ with index .spec.ports 0 }}{{ .port }}{{ end }}" service docker-registry)

registry="$(dig @${API_HOST} "docker-registry.default.svc.cluster.local." +short A | head -n 1)"
[[ -n "${registry}" && "${registry}:5000" == "${DOCKER_REGISTRY}" ]]

echo "[INFO] Verifying the docker-registry is up at ${DOCKER_REGISTRY}"
wait_for_url_timed "http://${DOCKER_REGISTRY}/healthz" "[INFO] Docker registry says: " $((2*TIME_MIN))

[ "$(dig @${API_HOST} "docker-registry.default.local." A)" ]

# Client setup (log in as e2e-user and set 'test' as the default project)
# This is required to be able to push to the registry!
echo "[INFO] Logging in as a regular user (e2e-user:pass) with project 'test'..."
oc login -u e2e-user -p pass
[ "$(oc whoami | grep 'e2e-user')" ]
 
# make sure viewers can see oc status
oc status -n default

# check to make sure a project admin can push an image
oc project cache
e2e_user_token=$(oc config view --flatten --minify -o template --template='{{with index .users 0}}{{.user.token}}{{end}}')
[[ -n ${e2e_user_token} ]]

echo "[INFO] Docker login as e2e-user to ${DOCKER_REGISTRY}"
docker login -u e2e-user -p ${e2e_user_token} -e e2e-user@openshift.com ${DOCKER_REGISTRY}
echo "[INFO] Docker login successful"

echo "[INFO] Tagging and pushing ruby-22-centos7 to ${DOCKER_REGISTRY}/cache/ruby-22-centos7:latest"
docker tag -f centos/ruby-22-centos7:latest ${DOCKER_REGISTRY}/cache/ruby-22-centos7:latest
docker push ${DOCKER_REGISTRY}/cache/ruby-22-centos7:latest
echo "[INFO] Pushed ruby-22-centos7"

# check to make sure an image-pusher can push an image
oc policy add-role-to-user system:image-pusher pusher
oc login -u pusher -p pass
pusher_token=$(oc config view --flatten --minify -o template --template='{{with index .users 0}}{{.user.token}}{{end}}')
[[ -n ${pusher_token} ]]

echo "[INFO] Docker login as pusher to ${DOCKER_REGISTRY}"
docker login -u e2e-user -p ${pusher_token} -e pusher@openshift.com ${DOCKER_REGISTRY}
echo "[INFO] Docker login successful"

# log back into docker as e2e-user again
docker login -u e2e-user -p ${e2e_user_token} -e e2e-user@openshift.com ${DOCKER_REGISTRY}

echo "[INFO] Back to 'default' project with 'admin' user..."
oc project ${CLUSTER_ADMIN_CONTEXT}
[ "$(oc whoami | grep 'system:admin')" ]

# The build requires a dockercfg secret in the builder service account in order
# to be able to push to the registry.  Make sure it exists first.
echo "[INFO] Waiting for dockercfg secrets to be generated in project 'test' before building"
wait_for_command "oc get -n test serviceaccount/builder -o yaml | grep dockercfg > /dev/null" $((60*TIME_SEC))

# Process template and create
echo "[INFO] Submitting application template json for processing..."
STI_CONFIG_FILE="${ARTIFACT_DIR}/stiAppConfig.json"
DOCKER_CONFIG_FILE="${ARTIFACT_DIR}/dockerAppConfig.json"
CUSTOM_CONFIG_FILE="${ARTIFACT_DIR}/customAppConfig.json"
oc process -n test -f examples/sample-app/application-template-stibuild.json > "${STI_CONFIG_FILE}"
oc process -n docker -f examples/sample-app/application-template-dockerbuild.json > "${DOCKER_CONFIG_FILE}"
oc process -n custom -f examples/sample-app/application-template-custombuild.json > "${CUSTOM_CONFIG_FILE}"

echo "[INFO] Back to 'test' context with 'e2e-user' user"
oc login -u e2e-user
oc project test
oc whoami

echo "[INFO] Running a CLI command in a container using the service account"
oc policy add-role-to-user view -z default
out=$(oc run cli-with-token --attach --env=POD_NAMESPACE=test --image=openshift/origin:${TAG} --restart=Never -- cli status --loglevel=4 2>&1)
echo $out
[ "$(echo $out | grep 'Using in-cluster configuration')" ]
[ "$(echo $out | grep 'In project test')" ]
oc delete pod cli-with-token
out=$(oc run cli-with-token-2 --attach --env=POD_NAMESPACE=test --image=openshift/origin:${TAG} --restart=Never -- cli whoami --loglevel=4 2>&1)
echo $out
[ "$(echo $out | grep 'system:serviceaccount:test:default')" ]
oc delete pod cli-with-token-2
out=$(oc run kubectl-with-token --attach --env=POD_NAMESPACE=test --image=openshift/origin:${TAG} --restart=Never --command -- kubectl get pods --loglevel=4 2>&1)
echo $out
[ "$(echo $out | grep 'Using in-cluster configuration')" ]
[ "$(echo $out | grep 'kubectl-with-token')" ]

echo "[INFO] Streaming the logs from a deployment twice..."
oc create -f test/fixtures/failing-dc.yaml
tryuntil oc get rc/failing-dc-1
oc logs -f dc/failing-dc
wait_for_command "oc get rc/failing-dc-1 --template={{.metadata.annotations}} | grep openshift.io/deployment.phase:Failed" $((20*TIME_SEC))
oc logs dc/failing-dc | grep 'test pre hook executed'
oc deploy failing-dc --latest
oc logs --version=1 dc/failing-dc

echo "[INFO] Applying STI application config"
oc create -f "${STI_CONFIG_FILE}"

# Wait for build which should have triggered automatically
echo "[INFO] Starting build from ${STI_CONFIG_FILE} and streaming its logs..."
#oc start-build -n test ruby-sample-build --follow
os::build:wait_for_start "test"
# Ensure that the build pod doesn't allow exec
[ "$(oc rsh ${BUILD_ID}-build 2>&1 | grep 'forbidden')" ]
os::build:wait_for_end "test"
wait_for_app "test"

# logs can't be tested without a node, so has to be in e2e
POD_NAME=$(oc get pods -n test --template='{{(index .items 0).metadata.name}}')
oc logs pod/${POD_NAME} --loglevel=6
oc logs ${POD_NAME} --loglevel=6
BUILD_NAME=$(oc get builds -n test --template='{{(index .items 0).metadata.name}}')
oc logs build/${BUILD_NAME} --loglevel=6
oc logs build/${BUILD_NAME} --loglevel=6
oc logs bc/ruby-sample-build --loglevel=6
oc logs buildconfigs/ruby-sample-build --loglevel=6
oc logs buildconfig/ruby-sample-build --loglevel=6
echo "logs: ok"

echo "[INFO] Starting a deployment to test scaling..."
oc create -f test/integration/fixtures/test-deployment-config.json
# scaling which might conflict with the deployment should work
oc scale dc/test-deployment-config --replicas=2
tryuntil '[ "$(oc get rc/test-deployment-config-1 -o yaml | grep Complete)" ]'
# scale rc via deployment configuration
oc scale dc/test-deployment-config --replicas=3 --timeout=1m
oc delete dc/test-deployment-config
echo "scale: ok"

echo "[INFO] Starting build from ${STI_CONFIG_FILE} with non-existing commit..."
set +e
oc start-build test --commit=fffffff --wait && echo "The build was supposed to fail, but it succeeded." && exit 1
set -e

# Remote command execution
echo "[INFO] Validating exec"
frontend_pod=$(oc get pod -l deploymentconfig=frontend --template='{{(index .items 0).metadata.name}}')
# when running as a restricted pod the registry will run with a pre-allocated
# user in the neighborhood of 1000000+.  Look for a substring of the pre-allocated uid range
[ "$(oc exec -p ${frontend_pod} id | grep 1000)" ]
[ "$(oc rsh ${frontend_pod} id -u | grep 1000)" ]
[ "$(oc rsh -T ${frontend_pod} id -u | grep 1000)" ]

# Port forwarding
echo "[INFO] Validating port-forward"
oc port-forward -p ${frontend_pod} 10080:8080  &> "${LOG_DIR}/port-forward.log" &
wait_for_url_timed "http://localhost:10080" "[INFO] Frontend says: " $((10*TIME_SEC))

# Rsync
echo "[INFO] Validating rsync"
oc rsync examples/sample-app ${frontend_pod}:/tmp
[ "$(oc rsh ${frontend_pod} ls /tmp/sample-app | grep "application-template-stibuild")" ]

#echo "[INFO] Applying Docker application config"
#oc create -n docker -f "${DOCKER_CONFIG_FILE}"
#echo "[INFO] Invoking generic web hook to trigger new docker build using curl"
#curl -k -X POST $API_SCHEME://$API_HOST:$API_PORT/osapi/v1beta3/namespaces/docker/buildconfigs/ruby-sample-build/webhooks/secret101/generic && sleep 3
#os::build:wait_for_end "docker"
#wait_for_app "docker"

#echo "[INFO] Applying Custom application config"
#oc create -n custom -f "${CUSTOM_CONFIG_FILE}"
#echo "[INFO] Invoking generic web hook to trigger new custom build using curl"
#curl -k -X POST $API_SCHEME://$API_HOST:$API_PORT/osapi/v1beta3/namespaces/custom/buildconfigs/ruby-sample-build/webhooks/secret101/generic && sleep 3
#os::build:wait_for_end "custom"
#wait_for_app "custom"

echo "[INFO] Back to 'default' project with 'admin' user..."
oc project ${CLUSTER_ADMIN_CONTEXT}

# ensure the router is started
# TODO: simplify when #4702 is fixed upstream
wait_for_command '[[ "$(oc get endpoints router --output-version=v1beta3 --template="{{ if .subsets }}{{ len .subsets }}{{ else }}0{{ end }}" || echo "0")" != "0" ]]' $((5*TIME_MIN))

# Check for privileged exec limitations.
echo "[INFO] Validating privileged pod exec"
router_pod=$(oc get pod -n default -l deploymentconfig=router --template='{{(index .items 0).metadata.name}}')
oc policy add-role-to-user admin e2e-default-admin
# login as a user that can't run privileged pods
oc login -u e2e-default-admin -p pass
# this next call should fail, but we want the output from it
set +e
output=$(oc exec -n default -tip ${router_pod} ls 2>&1)
set -e
echo "${output}" | grep -q "unable to validate against any security context constraint"
# system:admin should be able to exec into it
oc project ${CLUSTER_ADMIN_CONTEXT}
oc exec -n default -tip ${router_pod} ls


echo "[INFO] Validating routed app response..."
# use the docker bridge ip address until there is a good way to get the auto-selected address from master
# this address is considered stable
# used as a resolve IP to test routing
CONTAINER_ACCESSIBLE_API_HOST="${CONTAINER_ACCESSIBLE_API_HOST:-172.17.42.1}"
validate_response "-s -k --resolve www.example.com:443:${CONTAINER_ACCESSIBLE_API_HOST} https://www.example.com" "Hello from OpenShift" 0.2 50


# Pod node selection
echo "[INFO] Validating pod.spec.nodeSelector rejections"
# Create a project that enforces an impossible to satisfy nodeSelector, and two pods, one of which has an explicit node name
openshift admin new-project node-selector --description="This is an example project to test node selection prevents deployment" --admin="e2e-user" --node-selector="impossible-label=true"
NODE_NAME=`oc get node --no-headers | awk '{print $1}'`
oc process -n node-selector -v NODE_NAME="${NODE_NAME}" -f test/fixtures/node-selector/pods.json | oc create -n node-selector -f -
# The pod without a node name should fail to schedule
wait_for_command "oc get events -n node-selector | grep pod-without-node-name | grep FailedScheduling"        $((20*TIME_SEC))
# The pod with a node name should be rejected by the kubelet
wait_for_command "oc get events -n node-selector | grep pod-with-node-name    | grep NodeSelectorMismatching" $((20*TIME_SEC))


# Image pruning
echo "[INFO] Validating image pruning"
docker pull busybox
docker pull gcr.io/google_containers/pause
docker pull openshift/hello-openshift

# tag and push 1st image - layers unique to this image will be pruned
docker tag -f busybox ${DOCKER_REGISTRY}/cache/prune
docker push ${DOCKER_REGISTRY}/cache/prune

# tag and push 2nd image - layers unique to this image will be pruned
docker tag -f openshift/hello-openshift ${DOCKER_REGISTRY}/cache/prune
docker push ${DOCKER_REGISTRY}/cache/prune

# tag and push 3rd image - it won't be pruned
docker tag -f gcr.io/google_containers/pause ${DOCKER_REGISTRY}/cache/prune
docker push ${DOCKER_REGISTRY}/cache/prune

# record the storage before pruning
registry_pod=$(oc get pod -l deploymentconfig=docker-registry --template='{{(index .items 0).metadata.name}}')
oc exec -p ${registry_pod} du /registry > ${LOG_DIR}/prune-images.before.txt

# set up pruner user
oadm policy add-cluster-role-to-user system:image-pruner e2e-pruner
oc login -u e2e-pruner -p pass

# run image pruning
oadm prune images --keep-younger-than=0 --keep-tag-revisions=1 --confirm &> ${LOG_DIR}/prune-images.log
! grep error ${LOG_DIR}/prune-images.log

oc project ${CLUSTER_ADMIN_CONTEXT}
# record the storage after pruning
oc exec -p ${registry_pod} du /registry > ${LOG_DIR}/prune-images.after.txt

# make sure there were changes to the registry's storage
[ -n "$(diff ${LOG_DIR}/prune-images.before.txt ${LOG_DIR}/prune-images.after.txt)" ]


# UI e2e tests can be found in assets/test/e2e
if [[ "$TEST_ASSETS" == "true" ]]; then

  if [[ "$TEST_ASSETS_HEADLESS" == "true" ]]; then
    echo "[INFO] Starting virtual framebuffer for headless tests..."
    export DISPLAY=:10
    Xvfb :10 -screen 0 1024x768x24 -ac &
  fi

  echo "[INFO] Running UI e2e tests at time..."
  echo `date`
  pushd ${OS_ROOT}/assets > /dev/null
    grunt test-integration
  echo "UI  e2e done at time "
  echo `date`

  popd > /dev/null

fi

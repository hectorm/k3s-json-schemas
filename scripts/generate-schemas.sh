#!/bin/sh

set -eu

: "${K3S_VERSION:=latest}"
: "${K3S_IMAGE:=docker.io/rancher/k3s:${K3S_VERSION:?}}"

: "${OPENAPI2JSONSCHEMA_VERSION:=v0}"
: "${OPENAPI2JSONSCHEMA_IMAGE:=ghcr.io/hectorm/openapi2jsonschema:${OPENAPI2JSONSCHEMA_VERSION:?}}"

: "${SCHEMAS_DIR:="$(CDPATH='' cd -- "$(dirname -- "${0:?}")" && pwd -P)"/../schemas/}"
: "${SCHEMAS_TEMP_DIR:="$(mktemp -dt k3s-json-schema-XXXXXXXXXX)"}"

if [ -z "${NO_COLOR+x}" ] && [ -t 1 ]; then
	COLOR_RESET="$(tput sgr0)"
	COLOR_BRED="$(tput bold && tput setaf 1)"
	COLOR_BGREEN="$(tput bold && tput setaf 2)"
	COLOR_BYELLOW="$(tput bold && tput setaf 3)"
fi

printInfo() {  [ -n "${NO_STDOUT+x}" ] || printf "${COLOR_RESET-}[${COLOR_BGREEN-}INFO${COLOR_RESET-}] %s\n" "$@"; }
printWarn() {  [ -n "${NO_STDERR+x}" ] || printf "${COLOR_RESET-}[${COLOR_BYELLOW-}WARN${COLOR_RESET-}] %s\n" "$@" >&2; }
printError() { [ -n "${NO_STDERR+x}" ] || printf "${COLOR_RESET-}[${COLOR_BRED-}ERROR${COLOR_RESET-}] %s\n" "$@" >&2; }

cleanup() {
	[ -z "${K3S_CONTAINER_ID-}" ] || docker container stop "${K3S_CONTAINER_ID:?}" >/dev/null 2>&1 ||:
	[ -z "${NETWORK_ID-}"       ] || docker network rm "${NETWORK_ID:?}" >/dev/null 2>&1 ||:
	[ -z "${SCHEMAS_TEMP_DIR-}" ] || rm -rf "${SCHEMAS_TEMP_DIR:?}" ||:
}
trap cleanup EXIT TERM INT HUP

main() {
	printInfo 'Creating network'
	NETWORK_ID="$(docker network create "$(mktemp -u k3s-json-schema-XXXXXXXXXX)")"

	set --
	set -- "$@" --network "${NETWORK_ID:?}"
	set -- "$@" --network-alias server
	set -- "$@" --privileged
	set -- "$@" --ulimit nproc=65535
	set -- "$@" --ulimit nofile=65535:65535
	set -- "$@" --mount type=tmpfs,dst=/run/,tmpfs-size=100m
	set -- "$@" --mount type=tmpfs,dst=/var/run/,tmpfs-size=100m
	set -- "$@" --rm --detach
	set -- "$@" "${K3S_IMAGE:?}"

	printInfo 'Creating K3s server'
	K3S_CONTAINER_ID="$(docker container run "$@" server)"

	printInfo 'Waiting for K3s server to be ready'
	timeout 300 docker container exec "${K3S_CONTAINER_ID:?}" sh -euc "$(cat <<-'EOF'
		until {
			kubectl get --raw /readyz \
			&& kubectl get --raw /openapi/v2 \
			&& kubectl get --raw /apis/helm.cattle.io/v1/helmchartconfigs \
			&& kubectl get --raw /apis/helm.cattle.io/v1/helmcharts \
			&& kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes \
			&& kubectl get --raw /apis/metrics.k8s.io/v1beta1/pods \
			&& { kubectl get --raw /apis/traefik.io/v1alpha1/ingressroutes     || kubectl get --raw /apis/traefik.containo.us/v1alpha1/ingressroutes     ;} \
			&& { kubectl get --raw /apis/traefik.io/v1alpha1/ingressroutetcps  || kubectl get --raw /apis/traefik.containo.us/v1alpha1/ingressroutetcps  ;} \
			&& { kubectl get --raw /apis/traefik.io/v1alpha1/ingressrouteudps  || kubectl get --raw /apis/traefik.containo.us/v1alpha1/ingressrouteudps  ;} \
			&& { kubectl get --raw /apis/traefik.io/v1alpha1/middlewares       || kubectl get --raw /apis/traefik.containo.us/v1alpha1/middlewares       ;} \
			&& { kubectl get --raw /apis/traefik.io/v1alpha1/middlewaretcps    || kubectl get --raw /apis/traefik.containo.us/v1alpha1/middlewaretcps    ;} \
			&& { kubectl get --raw /apis/traefik.io/v1alpha1/serverstransports || kubectl get --raw /apis/traefik.containo.us/v1alpha1/serverstransports ;} \
			&& { kubectl get --raw /apis/traefik.io/v1alpha1/tlsoptions        || kubectl get --raw /apis/traefik.containo.us/v1alpha1/tlsoptions        ;} \
			&& { kubectl get --raw /apis/traefik.io/v1alpha1/tlsstores         || kubectl get --raw /apis/traefik.containo.us/v1alpha1/tlsstores         ;} \
			&& { kubectl get --raw /apis/traefik.io/v1alpha1/traefikservices   || kubectl get --raw /apis/traefik.containo.us/v1alpha1/traefikservices   ;} \
		;} >/dev/null 2>&1; do sleep 1; done
	EOF
	)" || { printError 'K3s server failed to start'; exit 1; }

	printInfo 'Starting kubectl proxy'
	docker container exec "${K3S_CONTAINER_ID:?}" sh -euc "$(cat <<-'EOF'
		kubectl proxy --address= --port=8181 --accept-hosts='.*' --accept-paths='^/openapi/.*$' &
	EOF
	)"

	printInfo 'Waiting for kubectl proxy to be ready'
	timeout 60 docker container exec "${K3S_CONTAINER_ID:?}" sh -euc "$(cat <<-'EOF'
		until {
			wget -qO /dev/null 'http://server:8181/openapi/v2' \
		;} >/dev/null 2>&1; do sleep 1; done
	EOF
	)" || { printError 'kubectl proxy failed to start'; exit 1; }

	set --
	set -- "$@" --net "${NETWORK_ID:?}"
	set -- "$@" --user "$(id -u):$(id -g)"
	set -- "$@" --mount type=bind,src="${SCHEMAS_TEMP_DIR:?}",dst=/schemas/
	set -- "$@" --rm --attach STDOUT --attach STDERR
	set -- "$@" "${OPENAPI2JSONSCHEMA_IMAGE:?}"

	printInfo 'Generating local schemas'
	docker container run "$@" --output /schemas/local/ --kubernetes --expanded 'http://server:8181/openapi/v2'

	printInfo 'Generating local strict schemas'
	docker container run "$@" --output /schemas/local-strict/ --kubernetes --expanded --strict 'http://server:8181/openapi/v2'

	printInfo 'Generating standalone schemas'
	docker container run "$@" --output /schemas/standalone/ --kubernetes --expanded --stand-alone 'http://server:8181/openapi/v2'

	printInfo 'Generating standalone strict schemas'
	docker container run "$@" --output /schemas/standalone-strict/ --kubernetes --expanded --stand-alone --strict 'http://server:8181/openapi/v2'

	printInfo 'All schemas successfully generated!'
	[ -d "${SCHEMAS_DIR:?}" ] || mkdir -p "${SCHEMAS_DIR:?}"
	rsync --recursive --checksum --delete --remove-source-files --verbose "${SCHEMAS_TEMP_DIR:?}"/ "${SCHEMAS_DIR:?}"/
}

main "$@"

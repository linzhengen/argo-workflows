export SHELL:=bash
export SHELLOPTS:=$(if $(SHELLOPTS),$(SHELLOPTS):)pipefail:errexit

# NOTE: Please ensure dependencies are synced with the flake.nix file in dev/nix/flake.nix before upgrading
# any external dependency. There is documentation on how to do this under the Developer Guide

USE_NIX := false
# https://stackoverflow.com/questions/4122831/disable-make-builtin-rules-and-variables-from-inside-the-make-file
MAKEFLAGS += --no-builtin-rules
.SUFFIXES:

# -- build metadata
BUILD_DATE            := $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
# below 3 are copied verbatim to release.yaml
GIT_COMMIT            := $(shell git rev-parse HEAD || echo unknown)
GIT_TAG               := $(shell git describe --exact-match --tags --abbrev=0  2> /dev/null || echo untagged)
GIT_TREE_STATE        := $(shell if [ -z "`git status --porcelain`" ]; then echo "clean" ; else echo "dirty"; fi)
GIT_REMOTE            := origin
GIT_BRANCH            := $(shell git rev-parse --symbolic-full-name --verify --quiet --abbrev-ref HEAD)
RELEASE_TAG           := $(shell if [[ "$(GIT_TAG)" =~ ^v[0-9]+\.[0-9]+\.[0-9]+.*$$ ]]; then echo "true"; else echo "false"; fi)
DEV_BRANCH            := $(shell [ "$(GIT_BRANCH)" = main ] || [ `echo $(GIT_BRANCH) | cut -c -8` = release- ] || [ `echo $(GIT_BRANCH) | cut -c -4` = dev- ] || [ $(RELEASE_TAG) = true ] && echo false || echo true)
SRC                   := $(GOPATH)/src/github.com/argoproj/argo-workflows
VERSION               := latest
# VERSION is the version to be used for files in manifests and should always be latest unless we are releasing
# we assume HEAD means you are on a tag
ifeq ($(RELEASE_TAG),true)
VERSION               := $(GIT_TAG)
endif

# -- docker image publishing options
IMAGE_NAMESPACE       ?= quay.io/argoproj
DOCKER_PUSH           ?= false
TARGET_PLATFORM       ?= linux/$(shell go env GOARCH)
K3D_CLUSTER_NAME      ?= k3s-default # declares which cluster to import to in case it's not the default name

# -- test options
E2E_WAIT_TIMEOUT      ?= 90s # timeout for wait conditions
E2E_PARALLEL          ?= 20
E2E_SUITE_TIMEOUT     ?= 15m
GOTEST                ?= go test -v -p 20
ALL_BUILD_TAGS        ?= api,cli,cron,executor,examples,corefunctional,functional,plugins
BENCHMARK_COUNT       ?= 6

# should we build the static files?
ifneq (,$(filter $(MAKECMDGOALS),codegen lint test docs start))
STATIC_FILES          := false
else
STATIC_FILES          ?= $(shell [ $(DEV_BRANCH) = true ] && echo false || echo true)
endif

# -- install & run options
PROFILE               ?= minimal
KUBE_NAMESPACE        ?= argo # namespace where Kubernetes resources/RBAC will be installed
PLUGINS               ?= $(shell [ $PROFILE = plugins ] && echo false || echo true)
UI                    ?= false # start the UI with HTTP
UI_SECURE             ?= false # start the UI with HTTPS
API                   ?= $(UI) # start the Argo Server
TASKS                 := controller
ifeq ($(API),true)
TASKS                 := controller server
endif
ifeq ($(UI_SECURE),true)
TASKS                 := controller server ui
endif
ifeq ($(UI),true)
TASKS                 := controller server ui
endif
# Which mode to run in:
# * `local` run the workflow–controller and argo-server as single replicas on the local machine (default)
# * `kubernetes` run the workflow-controller and argo-server on the Kubernetes cluster
RUN_MODE              := local
KUBECTX               := $(shell [[ "`which kubectl`" != '' ]] && kubectl config current-context || echo none)
K3D                   := $(shell [[ "$(KUBECTX)" == "k3d-"* ]] && echo true || echo false)
ifeq ($(PROFILE),prometheus)
RUN_MODE              := kubernetes
endif
ifeq ($(PROFILE),stress)
RUN_MODE              := kubernetes
endif

# -- controller + server + executor env vars
LOG_LEVEL                     := debug
UPPERIO_DB_DEBUG              := 0
DEFAULT_REQUEUE_TIME          ?= 1s # by keeping this short we speed up tests
ALWAYS_OFFLOAD_NODE_STATUS 	  := false
POD_STATUS_CAPTURE_FINALIZER  ?= true
NAMESPACED                    := true
MANAGED_NAMESPACE             ?= $(KUBE_NAMESPACE)
SECURE                        := false # whether or not to start Argo in TLS mode
AUTH_MODE                     := hybrid
ifeq ($(PROFILE),sso)
AUTH_MODE                     := sso
endif

$(info GIT_COMMIT=$(GIT_COMMIT) GIT_BRANCH=$(GIT_BRANCH) GIT_TAG=$(GIT_TAG) GIT_TREE_STATE=$(GIT_TREE_STATE) RELEASE_TAG=$(RELEASE_TAG) DEV_BRANCH=$(DEV_BRANCH) VERSION=$(VERSION))
$(info KUBECTX=$(KUBECTX) K3D=$(K3D) DOCKER_PUSH=$(DOCKER_PUSH) TARGET_PLATFORM=$(TARGET_PLATFORM))
$(info RUN_MODE=$(RUN_MODE) PROFILE=$(PROFILE) AUTH_MODE=$(AUTH_MODE) SECURE=$(SECURE) STATIC_FILES=$(STATIC_FILES) ALWAYS_OFFLOAD_NODE_STATUS=$(ALWAYS_OFFLOAD_NODE_STATUS) UPPERIO_DB_DEBUG=$(UPPERIO_DB_DEBUG) LOG_LEVEL=$(LOG_LEVEL) NAMESPACED=$(NAMESPACED))

override LDFLAGS += \
  -X github.com/argoproj/argo-workflows/v3.version=$(VERSION) \
  -X github.com/argoproj/argo-workflows/v3.buildDate=$(BUILD_DATE) \
  -X github.com/argoproj/argo-workflows/v3.gitCommit=$(GIT_COMMIT) \
  -X github.com/argoproj/argo-workflows/v3.gitTreeState=$(GIT_TREE_STATE)

ifneq ($(GIT_TAG),)
override LDFLAGS += -X github.com/argoproj/argo-workflows/v3.gitTag=${GIT_TAG}
endif

ifndef $(GOPATH)
	GOPATH:=$(shell go env GOPATH)
	export GOPATH
endif

# -- file lists
# These variables are only used as prereqs for the below targets, and we don't want to run them for other targets
# because the "go list" calls are very slow
ifneq (,$(filter dist/argoexec dist/workflow-controller dist/argo dist/argo-% docs/cli/argo.md,$(MAKECMDGOALS)))
HACK_PKG_FILES_AS_PKGS ?= false
ifeq ($(HACK_PKG_FILES_AS_PKGS),false)
	ARGOEXEC_PKG_FILES        := $(shell go list -f '{{ join .Deps "\n" }}' ./cmd/argoexec/ |  grep 'argoproj/argo-workflows/v3/' | xargs go list -f '{{ range $$file := .GoFiles }}{{ print $$.ImportPath "/" $$file "\n" }}{{ end }}' | cut -c 39-)
	CLI_PKG_FILES             := $(shell [ -f ui/dist/app/index.html ] || (mkdir -p ui/dist/app && touch ui/dist/app/placeholder); go list -f '{{ join .Deps "\n" }}' ./cmd/argo/ |  grep 'argoproj/argo-workflows/v3/' | xargs go list -f '{{ range $$file := .GoFiles }}{{ print $$.ImportPath "/" $$file "\n" }}{{ end }}' | cut -c 39-)
	CONTROLLER_PKG_FILES      := $(shell go list -f '{{ join .Deps "\n" }}' ./cmd/workflow-controller/ |  grep 'argoproj/argo-workflows/v3/' | xargs go list -f '{{ range $$file := .GoFiles }}{{ print $$.ImportPath "/" $$file "\n" }}{{ end }}' | cut -c 39-)
else
# Building argoexec on windows cannot rebuild the openapi, we need to fall back to the old
# behaviour where we fake dependencies and therefore don't rebuild
	ARGOEXEC_PKG_FILES    := $(shell echo cmd/argoexec            && go list -f '{{ join .Deps "\n" }}' ./cmd/argoexec/            | grep 'argoproj/argo-workflows/v3/' | cut -c 39-)
	CLI_PKG_FILES         := $(shell echo cmd/argo                && go list -f '{{ join .Deps "\n" }}' ./cmd/argo/                | grep 'argoproj/argo-workflows/v3/' | cut -c 39-)
	CONTROLLER_PKG_FILES  := $(shell echo cmd/workflow-controller && go list -f '{{ join .Deps "\n" }}' ./cmd/workflow-controller/ | grep 'argoproj/argo-workflows/v3/' | cut -c 39-)
endif
else
	ARGOEXEC_PKG_FILES    :=
	CLI_PKG_FILES         :=
	CONTROLLER_PKG_FILES  :=
endif

TYPES := $(shell find pkg/apis/workflow/v1alpha1 -type f -name '*.go' -not -name openapi_generated.go -not -name '*generated*' -not -name '*test.go')
CRDS := $(shell find manifests/base/crds -type f -name 'argoproj.io_*.yaml')
SWAGGER_FILES := pkg/apiclient/_.primary.swagger.json \
	pkg/apiclient/_.secondary.swagger.json \
	pkg/apiclient/clusterworkflowtemplate/cluster-workflow-template.swagger.json \
	pkg/apiclient/cronworkflow/cron-workflow.swagger.json \
	pkg/apiclient/event/event.swagger.json \
	pkg/apiclient/eventsource/eventsource.swagger.json \
	pkg/apiclient/info/info.swagger.json \
	pkg/apiclient/sensor/sensor.swagger.json \
	pkg/apiclient/workflow/workflow.swagger.json \
	pkg/apiclient/workflowarchive/workflow-archive.swagger.json \
	pkg/apiclient/workflowtemplate/workflow-template.swagger.json
PROTO_BINARIES := $(GOPATH)/bin/protoc-gen-gogo $(GOPATH)/bin/protoc-gen-gogofast $(GOPATH)/bin/goimports $(GOPATH)/bin/protoc-gen-grpc-gateway $(GOPATH)/bin/protoc-gen-swagger /usr/local/bin/clang-format

# protoc,my.proto
define protoc
	# protoc $(1)
    [ -e ./vendor ] || go mod vendor
    protoc \
      -I /usr/local/include \
      -I $(CURDIR) \
      -I $(CURDIR)/vendor \
      -I $(GOPATH)/src \
      -I $(GOPATH)/pkg/mod/github.com/gogo/protobuf@v1.3.2/gogoproto \
      -I $(GOPATH)/pkg/mod/github.com/grpc-ecosystem/grpc-gateway@v1.16.0/third_party/googleapis \
      --gogofast_out=plugins=grpc:$(GOPATH)/src \
      --grpc-gateway_out=logtostderr=true:$(GOPATH)/src \
      --swagger_out=logtostderr=true,fqn_for_swagger_name=true:. \
      $(1)
     perl -i -pe 's|argoproj/argo-workflows/|argoproj/argo-workflows/v3/|g' `echo "$(1)" | sed 's/proto/pb.go/g'`

endef

# cli

.PHONY: cli
cli: dist/argo

ui/dist/app/index.html: $(shell find ui/src -type f && find ui -maxdepth 1 -type f)
ifeq ($(STATIC_FILES),true)
	# `yarn install` is fast (~2s), so you can call it safely.
	JOBS=max yarn --cwd ui install
	# `yarn build` is slow, so we guard it with a up-to-date check.
	JOBS=max yarn --cwd ui build
else
	@mkdir -p ui/dist/app
	touch ui/dist/app/index.html
endif

dist/argo-linux-amd64: GOARGS = GOOS=linux GOARCH=amd64
dist/argo-linux-arm64: GOARGS = GOOS=linux GOARCH=arm64
dist/argo-linux-ppc64le: GOARGS = GOOS=linux GOARCH=ppc64le
dist/argo-linux-riscv64: GOARGS = GOOS=linux GOARCH=riscv64
dist/argo-linux-s390x: GOARGS = GOOS=linux GOARCH=s390x
dist/argo-darwin-amd64: GOARGS = GOOS=darwin GOARCH=amd64
dist/argo-darwin-arm64: GOARGS = GOOS=darwin GOARCH=arm64
dist/argo-windows-amd64: GOARGS = GOOS=windows GOARCH=amd64

dist/argo-windows-%.gz: dist/argo-windows-%
	gzip --force --keep dist/argo-windows-$*.exe

dist/argo-windows-%: ui/dist/app/index.html $(CLI_PKG_FILES) go.sum
	CGO_ENABLED=0 $(GOARGS) go build -v -gcflags '${GCFLAGS}' -ldflags '${LDFLAGS} -extldflags -static' -o $@.exe ./cmd/argo

dist/argo-%.gz: dist/argo-%
	gzip --force --keep dist/argo-$*

dist/argo-%: ui/dist/app/index.html $(CLI_PKG_FILES) go.sum
	CGO_ENABLED=0 $(GOARGS) go build -v -gcflags '${GCFLAGS}' -ldflags '${LDFLAGS} -extldflags -static' -o $@ ./cmd/argo

dist/argo: ui/dist/app/index.html $(CLI_PKG_FILES) go.sum
ifeq ($(shell uname -s),Darwin)
	# if local, then build fast: use CGO and dynamic-linking
	go build -v -gcflags '${GCFLAGS}' -ldflags '${LDFLAGS}' -o $@ ./cmd/argo
else
	CGO_ENABLED=0 go build -gcflags '${GCFLAGS}' -v -ldflags '${LDFLAGS} -extldflags -static' -o $@ ./cmd/argo
endif

argocli-image:

.PHONY: clis
clis: dist/argo-linux-amd64.gz dist/argo-linux-arm64.gz dist/argo-linux-ppc64le.gz dist/argo-linux-riscv64.gz dist/argo-linux-s390x.gz dist/argo-darwin-amd64.gz dist/argo-darwin-arm64.gz dist/argo-windows-amd64.gz

# controller

.PHONY: controller
controller: dist/workflow-controller

dist/workflow-controller: $(CONTROLLER_PKG_FILES) go.sum
ifeq ($(shell uname -s),Darwin)
	# if local, then build fast: use CGO and dynamic-linking
	go build -gcflags '${GCFLAGS}' -v -ldflags '${LDFLAGS}' -o $@ ./cmd/workflow-controller
else
	CGO_ENABLED=0 go build -gcflags '${GCFLAGS}' -v -ldflags '${LDFLAGS} -extldflags -static' -o $@ ./cmd/workflow-controller
endif

workflow-controller-image:

# argoexec

dist/argoexec: $(ARGOEXEC_PKG_FILES) go.sum
ifeq ($(shell uname -s),Darwin)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -gcflags '${GCFLAGS}' -v -ldflags '${LDFLAGS} -extldflags -static' -o $@ ./cmd/argoexec
else
	CGO_ENABLED=0 go build -v -gcflags '${GCFLAGS}' -ldflags '${LDFLAGS} -extldflags -static' -o $@ ./cmd/argoexec
endif

argoexec-image:

%-image:
	[ ! -e dist/$* ] || mv dist/$* .
	docker buildx build \
		--platform $(TARGET_PLATFORM) \
		--build-arg GIT_COMMIT=$(GIT_COMMIT) \
		--build-arg GIT_TAG=$(GIT_TAG) \
		--build-arg GIT_TREE_STATE=$(GIT_TREE_STATE) \
		-t $(IMAGE_NAMESPACE)/$*:$(VERSION) \
		--target $* \
		--load \
		 .
	[ ! -e $* ] || mv $* dist/
	docker run --rm -t $(IMAGE_NAMESPACE)/$*:$(VERSION) version
	if [ $(K3D) = true ]; then k3d image import -c $(K3D_CLUSTER_NAME) $(IMAGE_NAMESPACE)/$*:$(VERSION); fi
	if [ $(DOCKER_PUSH) = true ] && [ $(IMAGE_NAMESPACE) != argoproj ] ; then docker push $(IMAGE_NAMESPACE)/$*:$(VERSION) ; fi

.PHONY: codegen
codegen: types swagger manifests $(GOPATH)/bin/mockery docs/fields.md docs/cli/argo.md
	go generate ./...
	make --directory sdks/java USE_NIX=$(USE_NIX) generate
	make --directory sdks/python USE_NIX=$(USE_NIX) generate

.PHONY: check-pwd
check-pwd:

ifneq ($(SRC),$(PWD))
	@echo "⚠️ Code generation will not work if code in not checked out into $(SRC)" >&2
endif

.PHONY: types
types: check-pwd pkg/apis/workflow/v1alpha1/generated.proto pkg/apis/workflow/v1alpha1/openapi_generated.go pkg/apis/workflow/v1alpha1/zz_generated.deepcopy.go

.PHONY: swagger
swagger: \
	pkg/apiclient/clusterworkflowtemplate/cluster-workflow-template.swagger.json \
	pkg/apiclient/cronworkflow/cron-workflow.swagger.json \
	pkg/apiclient/event/event.swagger.json \
	pkg/apiclient/eventsource/eventsource.swagger.json \
	pkg/apiclient/info/info.swagger.json \
	pkg/apiclient/sensor/sensor.swagger.json \
	pkg/apiclient/workflow/workflow.swagger.json \
	pkg/apiclient/workflowarchive/workflow-archive.swagger.json \
	pkg/apiclient/workflowtemplate/workflow-template.swagger.json \
	manifests/base/crds/full/argoproj.io_workflows.yaml \
	manifests \
	api/openapi-spec/swagger.json \
	api/jsonschema/schema.json


$(GOPATH)/bin/mockery: Makefile
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	go install github.com/vektra/mockery/v2@v2.42.2
endif
$(GOPATH)/bin/controller-gen: Makefile
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.16.5
endif
$(GOPATH)/bin/go-to-protobuf: Makefile
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	# TODO: currently fails on v0.30.3 with
	# Unable to clean package k8s.io.api.core.v1: remove /home/runner/go/pkg/mod/k8s.io/api@v0.30.3/core/v1/generated.proto: permission denied
	go install k8s.io/code-generator/cmd/go-to-protobuf@v0.21.5
endif
$(GOPATH)/src/github.com/gogo/protobuf: Makefile
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	[ -e $@ ] || git clone --depth 1 https://github.com/gogo/protobuf.git -b v1.3.2 $@
endif
$(GOPATH)/bin/protoc-gen-gogo: Makefile
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	go install github.com/gogo/protobuf/protoc-gen-gogo@v1.3.2
endif
$(GOPATH)/bin/protoc-gen-gogofast: Makefile
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	go install github.com/gogo/protobuf/protoc-gen-gogofast@v1.3.2
endif
$(GOPATH)/bin/protoc-gen-grpc-gateway: Makefile
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	go install github.com/grpc-ecosystem/grpc-gateway/protoc-gen-grpc-gateway@v1.16.0
endif
$(GOPATH)/bin/protoc-gen-swagger: Makefile
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	go install github.com/grpc-ecosystem/grpc-gateway/protoc-gen-swagger@v1.16.0
endif
$(GOPATH)/bin/openapi-gen: Makefile
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	go install k8s.io/kube-openapi/cmd/openapi-gen@v0.0.0-20220124234850-424119656bbf
endif
$(GOPATH)/bin/swagger: Makefile
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	go install github.com/go-swagger/go-swagger/cmd/swagger@v0.31.0
endif
$(GOPATH)/bin/goimports: Makefile
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	go install golang.org/x/tools/cmd/goimports@v0.1.7
endif

/usr/local/bin/clang-format:
ifeq (, $(shell which clang-format))
ifeq ($(shell uname),Darwin)
	brew install clang-format
else
	sudo apt update
	sudo apt install -y clang-format
endif
endif

pkg/apis/workflow/v1alpha1/generated.proto: $(GOPATH)/bin/go-to-protobuf $(PROTO_BINARIES) $(TYPES) $(GOPATH)/src/github.com/gogo/protobuf
	# These files are generated on a v3/ folder by the tool. Link them to the root folder
	[ -e ./v3 ] || ln -s . v3
	# Format proto files. Formatting changes generated code, so we do it here, rather that at lint time.
	# Why clang-format? Google uses it.
	find pkg/apiclient -name '*.proto'|xargs clang-format -i
	$(GOPATH)/bin/go-to-protobuf \
		--go-header-file=./hack/custom-boilerplate.go.txt \
		--packages=github.com/argoproj/argo-workflows/v3/pkg/apis/workflow/v1alpha1 \
		--apimachinery-packages=+k8s.io/apimachinery/pkg/util/intstr,+k8s.io/apimachinery/pkg/api/resource,k8s.io/apimachinery/pkg/runtime/schema,+k8s.io/apimachinery/pkg/runtime,k8s.io/apimachinery/pkg/apis/meta/v1,k8s.io/api/core/v1,k8s.io/api/policy/v1 \
		--proto-import $(GOPATH)/src
	# Delete the link
	[ -e ./v3 ] && rm -rf v3
	touch pkg/apis/workflow/v1alpha1/generated.proto

# this target will also create a .pb.go and a .pb.gw.go file, but in Make 3 we cannot use _grouped target_, instead we must choose
# on file to represent all of them
pkg/apiclient/clusterworkflowtemplate/cluster-workflow-template.swagger.json: $(PROTO_BINARIES) $(TYPES) pkg/apiclient/clusterworkflowtemplate/cluster-workflow-template.proto
	$(call protoc,pkg/apiclient/clusterworkflowtemplate/cluster-workflow-template.proto)

pkg/apiclient/cronworkflow/cron-workflow.swagger.json: $(PROTO_BINARIES) $(TYPES) pkg/apiclient/cronworkflow/cron-workflow.proto
	$(call protoc,pkg/apiclient/cronworkflow/cron-workflow.proto)

pkg/apiclient/event/event.swagger.json: $(PROTO_BINARIES) $(TYPES) pkg/apiclient/event/event.proto
	$(call protoc,pkg/apiclient/event/event.proto)

pkg/apiclient/eventsource/eventsource.swagger.json: $(PROTO_BINARIES) $(TYPES) pkg/apiclient/eventsource/eventsource.proto
	$(call protoc,pkg/apiclient/eventsource/eventsource.proto)

pkg/apiclient/info/info.swagger.json: $(PROTO_BINARIES) $(TYPES) pkg/apiclient/info/info.proto
	$(call protoc,pkg/apiclient/info/info.proto)

pkg/apiclient/sensor/sensor.swagger.json: $(PROTO_BINARIES) $(TYPES) pkg/apiclient/sensor/sensor.proto
	$(call protoc,pkg/apiclient/sensor/sensor.proto)

pkg/apiclient/workflow/workflow.swagger.json: $(PROTO_BINARIES) $(TYPES) pkg/apiclient/workflow/workflow.proto
	$(call protoc,pkg/apiclient/workflow/workflow.proto)

pkg/apiclient/workflowarchive/workflow-archive.swagger.json: $(PROTO_BINARIES) $(TYPES) pkg/apiclient/workflowarchive/workflow-archive.proto
	$(call protoc,pkg/apiclient/workflowarchive/workflow-archive.proto)

pkg/apiclient/workflowtemplate/workflow-template.swagger.json: $(PROTO_BINARIES) $(TYPES) pkg/apiclient/workflowtemplate/workflow-template.proto
	$(call protoc,pkg/apiclient/workflowtemplate/workflow-template.proto)

# generate other files for other CRDs
manifests/base/crds/full/argoproj.io_workflows.yaml: $(GOPATH)/bin/controller-gen $(TYPES) ./hack/manifests/crdgen.sh ./hack/manifests/crds.go
	./hack/manifests/crdgen.sh

.PHONY: manifests
manifests: \
	manifests/install.yaml \
	manifests/namespace-install.yaml \
	manifests/quick-start-minimal.yaml \
	manifests/quick-start-mysql.yaml \
	manifests/quick-start-postgres.yaml \
	dist/manifests/install.yaml \
	dist/manifests/namespace-install.yaml \
	dist/manifests/quick-start-minimal.yaml \
	dist/manifests/quick-start-mysql.yaml \
	dist/manifests/quick-start-postgres.yaml

.PHONY: manifests/install.yaml
manifests/install.yaml: /dev/null
	kubectl kustomize --load-restrictor=LoadRestrictionsNone manifests/cluster-install | ./hack/manifests/auto-gen-msg.sh > manifests/install.yaml

.PHONY: manifests/namespace-install.yaml
manifests/namespace-install.yaml: /dev/null
	kubectl kustomize --load-restrictor=LoadRestrictionsNone manifests/namespace-install | ./hack/manifests/auto-gen-msg.sh > manifests/namespace-install.yaml

.PHONY: manifests/quick-start-minimal.yaml
manifests/quick-start-minimal.yaml: /dev/null
	kubectl kustomize --load-restrictor=LoadRestrictionsNone manifests/quick-start/minimal | ./hack/manifests/auto-gen-msg.sh > manifests/quick-start-minimal.yaml

.PHONY: manifests/quick-start-mysql.yaml
manifests/quick-start-mysql.yaml: /dev/null
	kubectl kustomize --load-restrictor=LoadRestrictionsNone manifests/quick-start/mysql | ./hack/manifests/auto-gen-msg.sh > manifests/quick-start-mysql.yaml

.PHONY: manifests/quick-start-postgres.yaml
manifests/quick-start-postgres.yaml: /dev/null
	kubectl kustomize --load-restrictor=LoadRestrictionsNone manifests/quick-start/postgres | ./hack/manifests/auto-gen-msg.sh > manifests/quick-start-postgres.yaml

dist/manifests/%: manifests/%
	@mkdir -p dist/manifests
	sed 's/:latest/:$(VERSION)/' manifests/$* > $@

# lint/test/etc

$(GOPATH)/bin/golangci-lint: Makefile
	curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b `go env GOPATH`/bin v1.61.0

.PHONY: lint
lint: ui/dist/app/index.html $(GOPATH)/bin/golangci-lint
	rm -Rf v3 vendor
	# If you're using `woc.wf.Spec` or `woc.execWf.Status` your code probably won't work with WorkflowTemplate.
	# * Change `woc.wf.Spec` to `woc.execWf.Spec`.
	# * Change `woc.execWf.Status` to `woc.wf.Status`.
	@awk '(/woc.wf.Spec/ || /woc.execWf.Status/) && !/not-woc-misuse/ {print FILENAME ":" FNR "\t" $0 ; exit 1}' $(shell find workflow/controller -type f -name '*.go' -not -name '*test*')
	# Tidy Go modules
	go mod tidy
	# Lint Go files
	$(GOPATH)/bin/golangci-lint run --fix --verbose
	# Lint the UI
	if [ -e ui/node_modules ]; then yarn --cwd ui lint ; fi
	# Deduplicate Node modules
	if [ -e ui/node_modules ]; then yarn --cwd ui deduplicate ; fi

# for local we have a faster target that prints to stdout, does not use json, and can cache because it has no coverage
.PHONY: test
test: ui/dist/app/index.html util/telemetry/metrics_list.go util/telemetry/attributes.go
	go build ./...
	env KUBECONFIG=/dev/null $(GOTEST) ./...
	# marker file, based on it's modification time, we know how long ago this target was run
	@mkdir -p dist
	touch dist/test

.PHONY: install
install: githooks
	kubectl get ns $(KUBE_NAMESPACE) || kubectl create ns $(KUBE_NAMESPACE)
	kubectl config set-context --current --namespace=$(KUBE_NAMESPACE)
	@echo "installing PROFILE=$(PROFILE)"
	kubectl kustomize --load-restrictor=LoadRestrictionsNone test/e2e/manifests/$(PROFILE) | sed 's|quay.io/argoproj/|$(IMAGE_NAMESPACE)/|' | sed 's/namespace: argo/namespace: $(KUBE_NAMESPACE)/' | kubectl -n $(KUBE_NAMESPACE) apply --prune -l app.kubernetes.io/part-of=argo -f -
ifeq ($(PROFILE),stress)
	kubectl -n $(KUBE_NAMESPACE) apply -f test/stress/massive-workflow.yaml
endif
ifeq ($(RUN_MODE),kubernetes)
	kubectl -n $(KUBE_NAMESPACE) scale deploy/workflow-controller --replicas 1
	kubectl -n $(KUBE_NAMESPACE) scale deploy/argo-server --replicas 1
endif
ifeq ($(UI_SECURE)$(PROFILE),truesso)
	KUBE_NAMESPACE=$(KUBE_NAMESPACE) ./hack/update-sso-redirect-url.sh
endif

.PHONY: argosay
argosay:
ifeq ($(DOCKER_PUSH),true)
	cd test/e2e/images/argosay/v2 && \
		docker buildx build \
			--platform linux/amd64,linux/arm64 \
			-t argoproj/argosay:v2 \
			--push \
			.
else
	cd test/e2e/images/argosay/v2 && \
		docker build . -t argoproj/argosay:v2
endif
ifeq ($(K3D),true)
	k3d image import -c $(K3D_CLUSTER_NAME) argoproj/argosay:v2
endif

.PHONY: argosayv1
argosayv1:
ifeq ($(DOCKER_PUSH),true)
	cd test/e2e/images/argosay/v1 && \
		docker buildx build \
			--platform linux/amd64,linux/arm64 \
			-t argoproj/argosay:v1 \
			--push \
			.
else
	cd test/e2e/images/argosay/v1 && \
		docker build . -t argoproj/argosay:v1
endif

dist/argosay:
	mkdir -p dist
	cp test/e2e/images/argosay/v2/argosay dist/

.PHONY: kit
kit: Makefile
ifeq ($(shell command -v kit),)
ifeq ($(shell uname),Darwin)
	brew tap kitproj/kit --custom-remote https://github.com/kitproj/kit
	brew install kit
else
	curl -q https://raw.githubusercontent.com/kitproj/kit/main/install.sh | tag=v0.1.8 sh
endif
endif


.PHONY: start
ifeq ($(RUN_MODE),local)
start: kit
else
start: install kit
endif
	@echo "starting STATIC_FILES=$(STATIC_FILES) (DEV_BRANCH=$(DEV_BRANCH), GIT_BRANCH=$(GIT_BRANCH)), AUTH_MODE=$(AUTH_MODE), RUN_MODE=$(RUN_MODE), MANAGED_NAMESPACE=$(MANAGED_NAMESPACE)"
ifneq ($(API),true)
	@echo "⚠️️  not starting API. If you want to test the API, use 'make start API=true' to start it"
endif
ifneq ($(UI),true)
	@echo "⚠️  not starting UI. If you want to test the UI, run 'make start UI=true' to start it"
endif
ifneq ($(PLUGINS),true)
	@echo "⚠️  not starting plugins. If you want to test plugins, run 'make start PROFILE=plugins' to start it"
endif
	# Check dex, minio, postgres and mysql are in hosts file
ifeq ($(AUTH_MODE),sso)
	grep '127.0.0.1.*dex' /etc/hosts
endif
	grep '127.0.0.1.*azurite' /etc/hosts
	grep '127.0.0.1.*minio' /etc/hosts
	grep '127.0.0.1.*postgres' /etc/hosts
	grep '127.0.0.1.*mysql' /etc/hosts
ifeq ($(RUN_MODE),local)
	env DEFAULT_REQUEUE_TIME=$(DEFAULT_REQUEUE_TIME) ARGO_SECURE=$(SECURE) ALWAYS_OFFLOAD_NODE_STATUS=$(ALWAYS_OFFLOAD_NODE_STATUS) ARGO_LOGLEVEL=$(LOG_LEVEL) UPPERIO_DB_DEBUG=$(UPPERIO_DB_DEBUG) ARGO_AUTH_MODE=$(AUTH_MODE) ARGO_NAMESPACED=$(NAMESPACED) ARGO_NAMESPACE=$(KUBE_NAMESPACE) ARGO_MANAGED_NAMESPACE=$(MANAGED_NAMESPACE) ARGO_EXECUTOR_PLUGINS=$(PLUGINS) ARGO_POD_STATUS_CAPTURE_FINALIZER=$(POD_STATUS_CAPTURE_FINALIZER) ARGO_UI_SECURE=$(UI_SECURE) PROFILE=$(PROFILE) kit $(TASKS)
endif

.PHONY: wait
wait:
	# Wait for workflow controller
	until lsof -i :9090 > /dev/null ; do sleep 10s ; done
ifeq ($(API),true)
	# Wait for Argo Server
	until lsof -i :2746 > /dev/null ; do sleep 10s ; done
endif
ifeq ($(PROFILE),mysql)
	# Wait for MySQL
	until (: < /dev/tcp/localhost/3306) ; do sleep 10s ; done
endif

.PHONY: postgres-cli
postgres-cli:
	kubectl exec -ti svc/postgres -- psql -U postgres

.PHONY: postgres-dump
postgres-dump:
	@mkdir -p db-dumps
	kubectl exec svc/postgres -- pg_dump --clean -U postgres > "db-dumps/postgres-$(BUILD_DATE).sql"

.PHONY: mysql-cli
mysql-cli:
	kubectl exec -ti svc/mysql -- mysql -u mysql -ppassword argo

.PHONY: mysql-dump
mysql-dump:
	@mkdir -p db-dumps
	kubectl exec svc/mysql -- mysqldump --no-tablespaces -u mysql -ppassword argo > "db-dumps/mysql-$(BUILD_DATE).sql"


test-cli: ./dist/argo

test-%:
	E2E_WAIT_TIMEOUT=$(E2E_WAIT_TIMEOUT) go test -failfast -v -timeout $(E2E_SUITE_TIMEOUT) -count 1 --tags $* -parallel $(E2E_PARALLEL) ./test/e2e

.PHONY: test-examples
test-examples:
	./hack/test-examples.sh

.PHONY: test-%-sdk
test-%-sdk:
	make --directory sdks/$* install test -B

Test%:
	E2E_WAIT_TIMEOUT=$(E2E_WAIT_TIMEOUT) go test -failfast -v -timeout $(E2E_SUITE_TIMEOUT) -count 1 --tags $(ALL_BUILD_TAGS) -parallel $(E2E_PARALLEL) ./test/e2e  -run='.*/$*'

Benchmark%:
	go test --tags $(ALL_BUILD_TAGS) ./test/e2e -run='$@' -benchmem -count=$(BENCHMARK_COUNT) -bench .

# clean

.PHONY: clean
clean:
	go clean
	rm -Rf test-results node_modules vendor v2 v3 argoexec-linux-amd64 dist/* ui/dist

# Build telemetry files
TELEMETRY_BUILDER := $(shell find util/telemetry/builder -type f -name '*.go')
docs/metrics.md: $(TELEMETRY_BUILDER) util/telemetry/builder/values.yaml
	@echo Rebuilding $@
	go run ./util/telemetry/builder --metricsDocs $@

util/telemetry/metrics_list.go: $(TELEMETRY_BUILDER) util/telemetry/builder/values.yaml
	@echo Rebuilding $@
	go run ./util/telemetry/builder --metricsListGo $@

util/telemetry/attributes.go: $(TELEMETRY_BUILDER) util/telemetry/builder/values.yaml
	@echo Rebuilding $@
	go run ./util/telemetry/builder --attributesGo $@

# swagger
pkg/apis/workflow/v1alpha1/openapi_generated.go: $(GOPATH)/bin/openapi-gen $(TYPES)
	# These files are generated on a v3/ folder by the tool. Link them to the root folder
	[ -e ./v3 ] || ln -s . v3
	$(GOPATH)/bin/openapi-gen \
	  --go-header-file ./hack/custom-boilerplate.go.txt \
	  --input-dirs github.com/argoproj/argo-workflows/v3/pkg/apis/workflow/v1alpha1 \
	  --output-package github.com/argoproj/argo-workflows/v3/pkg/apis/workflow/v1alpha1 \
	  --report-filename pkg/apis/api-rules/violation_exceptions.list
	# Force the timestamp to be up to date
	touch $@
	# Delete the link
	[ -e ./v3 ] && rm -rf v3


# generates many other files (listers, informers, client etc).
.PRECIOUS: pkg/apis/workflow/v1alpha1/zz_generated.deepcopy.go
pkg/apis/workflow/v1alpha1/zz_generated.deepcopy.go: $(GOPATH)/bin/go-to-protobuf $(TYPES)
	# These files are generated on a v3/ folder by the tool. Link them to the root folder
	[ -e ./v3 ] || ln -s . v3
	bash $(GOPATH)/pkg/mod/k8s.io/code-generator@v0.21.5/generate-groups.sh \
	    "deepcopy,client,informer,lister" \
	    github.com/argoproj/argo-workflows/v3/pkg/client github.com/argoproj/argo-workflows/v3/pkg/apis \
	    workflow:v1alpha1 \
	    --go-header-file ./hack/custom-boilerplate.go.txt
	# Force the timestamp to be up to date
	touch $@
	# Delete the link
	[ -e ./v3 ] && rm -rf v3

dist/kubernetes.swagger.json: Makefile
	@mkdir -p dist
	# recurl will only fetch if the file doesn't exist, so delete it
	rm -f $@
	./hack/recurl.sh $@ https://raw.githubusercontent.com/kubernetes/kubernetes/v1.31.3/api/openapi-spec/swagger.json

pkg/apiclient/_.secondary.swagger.json: hack/api/swagger/secondaryswaggergen.go pkg/apis/workflow/v1alpha1/openapi_generated.go dist/kubernetes.swagger.json
	rm -Rf v3 vendor
	# We have `hack/api/swagger` so that most hack script do not depend on the whole code base and are therefore slow.
	go run ./hack/api/swagger secondaryswaggergen

# we always ignore the conflicts, so lets automated figuring out how many there will be and just use that
dist/swagger-conflicts: $(GOPATH)/bin/swagger $(SWAGGER_FILES)
	swagger mixin $(SWAGGER_FILES) 2>&1 | grep -c skipping > dist/swagger-conflicts || true

dist/mixed.swagger.json: $(GOPATH)/bin/swagger $(SWAGGER_FILES) dist/swagger-conflicts
	swagger mixin -c $(shell cat dist/swagger-conflicts) $(SWAGGER_FILES) -o dist/mixed.swagger.json

dist/swaggifed.swagger.json: dist/mixed.swagger.json hack/api/swagger/swaggify.sh
	cat dist/mixed.swagger.json | ./hack/api/swagger/swaggify.sh > dist/swaggifed.swagger.json

dist/kubeified.swagger.json: dist/swaggifed.swagger.json dist/kubernetes.swagger.json
	go run ./hack/api/swagger kubeifyswagger dist/swaggifed.swagger.json dist/kubeified.swagger.json

dist/swagger.0.json: $(GOPATH)/bin/swagger dist/kubeified.swagger.json
	swagger flatten --with-flatten minimal --with-flatten remove-unused dist/kubeified.swagger.json -o dist/swagger.0.json

api/openapi-spec/swagger.json: $(GOPATH)/bin/swagger dist/swagger.0.json
	swagger flatten --with-flatten remove-unused dist/swagger.0.json -o api/openapi-spec/swagger.json

api/jsonschema/schema.json: api/openapi-spec/swagger.json hack/api/jsonschema/main.go
	go run ./hack/api/jsonschema

go-diagrams/diagram.dot: ./hack/docs/diagram.go
	rm -Rf go-diagrams
	go run ./hack/docs diagram

docs/assets/diagram.png: go-diagrams/diagram.dot
	cd go-diagrams && dot -Tpng diagram.dot -o ../docs/assets/diagram.png

docs/fields.md: api/openapi-spec/swagger.json $(shell find examples -type f) ui/dist/app/index.html hack/docs/fields.go
	env ARGO_SECURE=false ARGO_INSECURE_SKIP_VERIFY=false ARGO_SERVER= ARGO_INSTANCEID= go run ./hack/docs fields

# generates several other files
docs/cli/argo.md: $(CLI_PKG_FILES) go.sum ui/dist/app/index.html hack/docs/cli.go
	go run ./hack/docs cli

# docs

/usr/local/bin/mdspell: Makefile
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	npm list -g markdown-spellcheck@1.3.1 > /dev/null || npm i -g markdown-spellcheck@1.3.1
endif

.PHONY: docs-spellcheck
docs-spellcheck: /usr/local/bin/mdspell docs/metrics.md
	# check docs for spelling mistakes
	mdspell --ignore-numbers --ignore-acronyms --en-us --no-suggestions --report $(shell find docs -name '*.md' -not -name upgrading.md -not -name README.md -not -name fields.md -not -name upgrading.md -not -name executor_swagger.md -not -path '*/cli/*')
	# alphabetize spelling file -- ignore first line (comment), then sort the rest case-sensitive and remove duplicates
	$(shell cat .spelling | awk 'NR<2{ print $0; next } { print $0 | "LC_COLLATE=C sort" }' | uniq | tee .spelling > /dev/null)

/usr/local/bin/markdown-link-check:
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	npm list -g markdown-link-check@3.11.1 > /dev/null || npm i -g markdown-link-check@3.11.1
endif

.PHONY: docs-linkcheck
docs-linkcheck: /usr/local/bin/markdown-link-check
	# check docs for broken links
	markdown-link-check -q -c .mlc_config.json $(shell find docs -name '*.md' -not -name fields.md -not -name executor_swagger.md)

/usr/local/bin/markdownlint:
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	npm list -g markdownlint-cli@0.33.0 > /dev/null || npm i -g markdownlint-cli@0.33.0
endif


.PHONY: docs-lint
docs-lint: /usr/local/bin/markdownlint docs/metrics.md
	# lint docs
	markdownlint docs --fix --ignore docs/fields.md --ignore docs/executor_swagger.md --ignore docs/cli --ignore docs/walk-through/the-structure-of-workflow-specs.md

/usr/local/bin/mkdocs:
# update this in Nix when upgrading it here
ifneq ($(USE_NIX), true)
	python -m pip install --no-cache-dir -r docs/requirements.txt
endif

.PHONY: docs
docs: /usr/local/bin/mkdocs \
	docs-spellcheck \
	docs-lint \
	# TODO: This is temporarily disabled to unblock merging PRs.
	# docs-linkcheck
	# copy README.md to docs/README.md
	./hack/docs/copy-readme.sh
	# check environment-variables.md contains all variables mentioned in the code
	./hack/docs/check-env-doc.sh
	# build the docs
	TZ=UTC mkdocs build --strict
	# tell the user the fastest way to edit docs
	@echo "ℹ️ If you want to preview your docs, open site/index.html. If you want to edit them with hot-reload, run 'make docs-serve' to start mkdocs on port 8000"

.PHONY: docs-serve
docs-serve: docs
	mkdocs serve

# pre-commit checks

.git/hooks/%: hack/git/hooks/%
	@mkdir -p .git/hooks
	cp hack/git/hooks/$* .git/hooks/$*

.PHONY: githooks
githooks: .git/hooks/pre-commit .git/hooks/commit-msg

.PHONY: pre-commit
pre-commit: codegen lint docs
	# marker file, based on it's modification time, we know how long ago this target was run
	touch dist/pre-commit

# release

release-notes: /dev/null
	version=$(VERSION) envsubst '$$version' < hack/release-notes.md > release-notes

.PHONY: checksums
checksums:
	sha256sum ./dist/argo-*.gz | awk -F './dist/' '{print $$1 $$2}' > ./dist/argo-workflows-cli-checksums.txt

# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

.PHONY: all clean push update-prepare update test-check test-update test-unit test-lint test-lint-prepare image test-boilerplate deploy
.DELETE_ON_ERROR:

SHELL=/bin/bash -o pipefail
BIN_DIR=bin
PKG_CONFIG=.pkg_config
PKG_CONFIG_CONTENT=$(shell cat $(PKG_CONFIG))
TEST_RESULTS_DIR=testResults
# TODO: fix code and enable more options
# -E deadcode -E gocyclo -E vetshadow -E gas -E ineffassign
GOMETALINTER_OPTION=--tests --disable-all -E gofmt -E vet -E golint -e "don't use underscores in Go names"

IMAGE_REGISTRY ?= local
K8S_VERSION ?= v1.15.0
AKSENGINE_VERSION ?= master
HYPERKUBE_IMAGE ?= gcrio.azureedge.net/google_containers/hyperkube-amd64:$(K8S_VERSION)
# manifest name under tests/e2e/k8s-azure/manifest
TEST_MANIFEST ?= linux
# build hyperkube image when specified
K8S_BRANCH ?=
# Only run conformance tests by default (non-serial and non-slow)
# Note autoscaling tests would be skiped as well.
CCM_E2E_ARGS ?= -ginkgo.skip=\\[Serial\\]\\[Slow\\]
#The test args for Kubernetes e2e tests
TEST_E2E_ARGS ?= '--ginkgo.focus=Port\sforwarding'

IMAGE_NAME=azure-cloud-controller-manager
IMAGE_TAG ?= $(shell git rev-parse --short=7 HEAD)
IMAGE=$(IMAGE_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

TEST_IMAGE_NAME=azure-cloud-controller-manager-test
TEST_IMAGE=$(TEST_IMAGE_NAME):$(IMAGE_TAG)

WORKSPACE ?= $(shell pwd)
ARTIFACTS ?= $(WORKSPACE)/_artifacts

all: $(BIN_DIR)/azure-cloud-controller-manager

clean:
	rm -rf $(BIN_DIR) $(PKG_CONFIG) $(TEST_RESULTS_DIR)

$(BIN_DIR)/azure-cloud-controller-manager: $(PKG_CONFIG) $(wildcard cmd/cloud-controller-manager/*) $(wildcard cmd/cloud-controller-manager/**/*) $(wildcard pkg/**/*)
	 go build -o $@ $(PKG_CONFIG_CONTENT) ./cmd/cloud-controller-manager

image:
	docker build -t $(IMAGE) .

push:
	docker push $(IMAGE)

hyperkube:
ifneq ($(K8S_BRANCH), )
	$(eval K8S_VERSION=$(shell REGISTRY=$(IMAGE_REGISTRY) BRANCH=$(K8S_BRANCH) hack/build-hyperkube.sh))
	$(eval HYPERKUBE_IMAGE=$(IMAGE_REGISTRY)/hyperkube-amd64:$(K8S_VERSION))
endif

$(PKG_CONFIG):
	hack/pkg-config.sh > $@

test-unit: $(PKG_CONFIG)
	mkdir -p $(TEST_RESULTS_DIR)
	cd ./cmd/cloud-controller-manager && go test $(PKG_CONFIG_CONTENT) -v ./... | tee ../../$(TEST_RESULTS_DIR)/unittest.txt
ifdef JUNIT
	hack/convert-test-report.pl $(TEST_RESULTS_DIR)/unittest.txt > $(TEST_RESULTS_DIR)/unittest.xml
endif

# collection of check tests
test-check: test-lint-prepare test-lint test-boilerplate

test-lint-prepare:
	GO111MODULE=off go get -u gopkg.in/alecthomas/gometalinter.v1
	GO111MODULE=off gometalinter.v1 -i
test-lint:
	gometalinter.v1 $(GOMETALINTER_OPTION) ./ ./cmd/cloud-controller-manager/...
	gometalinter.v1 $(GOMETALINTER_OPTION) -e "should not use dot imports" tests/e2e/...

test-boilerplate:
	hack/verify-boilerplate.sh

update-prepare:
	go get -u github.com/sgotti/glide-vc
	go get -u github.com/Masterminds/glide
update:
	hack/update-dependencies.sh
test-update: update-prepare update
	git checkout glide.lock
	git add -A .
	git diff --staged --name-status --exit-code || { \
		echo "You have committed changes after running 'make update', please check"; \
		exit 1; \
	} \

test-e2e:
	hack/test_k8s_e2e.sh $(TEST_E2E_ARGS)


test-ccm-e2e:
	go test ./tests/e2e/ -timeout 0 -v $(CCM_E2E_ARGS)

deploy: image hyperkube	push
	IMAGE=$(IMAGE) HYPERKUBE_IMAGE=$(HYPERKUBE_IMAGE) hack/deploy-cluster.sh

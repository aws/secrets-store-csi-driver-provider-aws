$(eval AWS_REGION=$(shell echo $${REGION:-us-east-1}))
$(eval REGISTRY_NAME=$(shell echo $${PRIVREPO:-public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws}))
$(eval REPOBASE=$(shell echo $(REGISTRY_NAME) | cut -f1 -d/))

ifeq ($(REPOBASE), public.ecr.aws)
ECRCMD=ecr-public
else
ECRCMD=ecr
endif

IMAGE_NAME=secrets-store-csi-driver-provider-aws

BASE_REV=1.0
$(eval BUILD_DATE=$(shell date -u +%Y.%m.%d.%H.%M))
$(eval MINOR_REV=$(shell git describe --always))
REV=$(BASE_REV).$(MINOR_REV)-$(BUILD_DATE)

LDFLAGS?="-X github.com/aws/secrets-store-csi-driver-provider-aws/server.Version=$(REV) -extldflags "-static""

DEPS := go.mod go.sum main.go $(wildcard auth/*.go) $(wildcard provider/*.go) $(wildcard server/*.go)

# Build docker image and push to AWS registry
all: clean build docker-login docker-buildx-push

_output/$(IMAGE_NAME): $(DEPS)
	CGO_ENABLED=0 go build -a -ldflags ${LDFLAGS} -o $@

.PHONY: build
build: _output/$(IMAGE_NAME)

.PHONY: clean
clean:
	-rm -rf _output
	-docker system prune --all --force

.PHONY: docker-login
docker-login:
	[ -z "$$SKIP_DOCKER_LOGIN" ] && aws --region $(AWS_REGION) $(ECRCMD) get-login-password | docker login -u AWS --password-stdin $(REPOBASE)

# Build Docker image and push it. Foreign architecture images can't be loaded into
# the local Docker engine, so we must perform the build and push together in a
# single step (unless we want to manage tarballs ourselves, which we do not).
.PHONY: docker-buildx-push
docker-buildx-push:
	docker buildx build \
		--build-arg LDFLAGS=$(LDFLAGS) \
		--platform linux/amd64,linux/arm64 \
		--push \
		-t $(REGISTRY_NAME):$(REV) \
		-t $(REGISTRY_NAME):latest \
		.

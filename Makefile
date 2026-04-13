$(eval AWS_REGION=$(shell echo $${REGION:-us-east-1}))
$(eval REGISTRY_NAME=$(shell echo $${PRIVREPO:-public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws}))
$(eval REPOBASE=$(shell echo $(REGISTRY_NAME) | cut -f1 -d/))

ifeq ($(REPOBASE), public.ecr.aws)
ECRCMD=ecr-public
else
ECRCMD=ecr
endif

MAJOR_REV=3
MINOR_REV=0
PATCH_REV=0
FULL_REV=$(MAJOR_REV).$(MINOR_REV).$(PATCH_REV)

LDFLAGS?="-X github.com/aws/secrets-store-csi-driver-provider-aws/server.Version=$(FULL_REV) \
		  -X github.com/aws/secrets-store-csi-driver-provider-aws/server.ProviderVersion=$(FULL_REV) \
		  -extldflags "-static""

CHART_RELEASER_PATH ?= cr

CONTAINER_TOOL ?= $(shell command -v docker >/dev/null 2>&1 && echo docker || (command -v finch >/dev/null 2>&1 && echo finch))
ifndef CONTAINER_TOOL
$(error No container tool found. Install docker or finch)
endif

.PHONY: all clean ensure-finch-vm docker-login docker-buildx

# Build docker image and push to AWS registry
all: clean docker-login docker-buildx

ensure-finch-vm:
ifeq ($(CONTAINER_TOOL),finch)
	@STATUS=$$(finch vm status 2>&1); \
	if echo "$$STATUS" | grep -q "Running"; then \
		echo "Finch VM already running"; \
	elif echo "$$STATUS" | grep -q "Stopped"; then \
		echo "Starting finch VM..."; \
		finch vm start; \
	else \
		echo "Initializing finch VM..."; \
		finch vm init; \
	fi
endif

clean:
	-rm -rf _output
	-$(CONTAINER_TOOL) system prune --all --force

docker-login: ensure-finch-vm
	# Logging into ecr-public is required to pull the Amazon Linux 2 image used for the build
	aws --region us-east-1 ecr-public get-login-password | $(CONTAINER_TOOL) login -u AWS --password-stdin public.ecr.aws
	@if [[ "$(REPOBASE)" != "public.ecr.aws" ]]; then\
		aws --region $(AWS_REGION) ecr get-login-password | $(CONTAINER_TOOL) login -u AWS --password-stdin $(REPOBASE);\
	fi

# Build, tag, and push multi-architecture image.
docker-buildx: ensure-finch-vm
ifeq ($(CONTAINER_TOOL),docker)
	@!(docker manifest inspect $(REGISTRY_NAME):$(FULL_REV) > /dev/null 2>&1) || (echo "Version already exists"; exit 1)

	docker buildx build \
				--platform linux/arm64,linux/amd64 \
				--build-arg LDFLAGS=$(LDFLAGS) \
				--push \
				-t $(REGISTRY_NAME):latest \
				-t $(REGISTRY_NAME):$(FULL_REV) \
				-t $(REGISTRY_NAME):$(MAJOR_REV) \
				-t $(REGISTRY_NAME):latest-amd64 \
				-t $(REGISTRY_NAME):latest-arm64 \
				-t $(REGISTRY_NAME):latest-linux-amd64 \
				-t $(REGISTRY_NAME):latest-linux-arm64 \
				-t $(REGISTRY_NAME):$(FULL_REV)-linux-amd64 \
				-t $(REGISTRY_NAME):$(FULL_REV)-linux-arm64 \
				. ;
else
	@echo "Skipping remote manifest check (not supported by $(CONTAINER_TOOL))"

	$(CONTAINER_TOOL) build --provenance=false \
				--platform linux/arm64,linux/amd64 \
				--build-arg LDFLAGS=$(LDFLAGS) \
				--output 'type=image,"name=$(REGISTRY_NAME):latest,$(REGISTRY_NAME):$(FULL_REV),$(REGISTRY_NAME):$(MAJOR_REV),$(REGISTRY_NAME):latest-amd64,$(REGISTRY_NAME):latest-arm64,$(REGISTRY_NAME):latest-linux-amd64,$(REGISTRY_NAME):latest-linux-arm64,$(REGISTRY_NAME):$(FULL_REV)-linux-amd64,$(REGISTRY_NAME):$(FULL_REV)-linux-arm64",push=true' \
				. ; \
				EXIT=$$?; \
				if [ $$EXIT -ne 0 ]; then \
					echo "WARNING: Build exited $$EXIT. If all tags were pushed, this may be a known BuildKit issue pushing unnamed manifests."; \
					exit $$EXIT; \
				fi
endif

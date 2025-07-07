$(eval AWS_REGION=$(shell echo $${REGION:-us-east-1}))
$(eval REGISTRY_NAME=$(shell echo $${PRIVREPO:-public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws}))
$(eval REPOBASE=$(shell echo $(REGISTRY_NAME) | cut -f1 -d/))

ifeq ($(REPOBASE), public.ecr.aws)
ECRCMD=ecr-public
else
ECRCMD=ecr
endif

MAJOR_REV=1
MINOR_REV=1
$(eval PATCH_REV=$(shell git describe --always))
$(eval BUILD_DATE=$(shell date -u +%Y.%m.%d.%H.%M))
FULL_REV=$(MAJOR_REV).$(MINOR_REV).$(PATCH_REV)-$(BUILD_DATE)

LDFLAGS?="-X github.com/aws/secrets-store-csi-driver-provider-aws/server.Version=$(FULL_REV) \
		  -X github.com/aws/secrets-store-csi-driver-provider-aws/auth.ProviderVersion=$(FULL_REV) \
		  -extldflags "-static""

CHART_RELEASER_PATH ?= cr

.PHONY: all clean docker-login docker-buildx

# Build docker image and push to AWS registry
all: clean docker-login docker-buildx

clean:
	-rm -rf _output
	-docker system prune --all --force

docker-login:
	# Logging into ecr-public is required to pull the Amazon Linux 2 image used for the build
	aws --region us-east-1 ecr-public get-login-password | docker login -u AWS --password-stdin public.ecr.aws
	@if [[ "$(REPOBASE)" != "public.ecr.aws" ]]; then\
		aws --region $(AWS_REGION) ecr get-login-password | docker login -u AWS --password-stdin $(REPOBASE);\
	fi

# Build, tag, and push multi-architecture image.
docker-buildx:
	@!(docker manifest inspect $(REGISTRY_NAME):$(FULL_REV) > /dev/null) || (echo "Version already exists"; exit 1)

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

# Get a GitHub personal access token from the "Developer settings" section of your Github Account settings
upload-helm:
	cd charts/secrets-store-csi-driver-provider-aws && ${CHART_RELEASER_PATH} package
	cd charts/secrets-store-csi-driver-provider-aws && ${CHART_RELEASER_PATH} upload -o aws -r secrets-store-csi-driver-provider-aws --token $(GITHUB_TOKEN) --skip-existing
	cd charts/secrets-store-csi-driver-provider-aws && ${CHART_RELEASER_PATH} index -o aws -r secrets-store-csi-driver-provider-aws --token $(GITHUB_TOKEN) --push --index-path .

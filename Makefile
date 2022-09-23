$(eval AWS_REGION=$(shell echo $${REGION:-us-east-1}))
$(eval REGISTRY_NAME=$(shell echo $${PRIVREPO:-public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws}))
$(eval REPOBASE=$(shell echo $(REGISTRY_NAME) | cut -f1 -d/))

ifeq ($(REPOBASE), public.ecr.aws)
ECRCMD=ecr-public
else
ECRCMD=ecr
endif

IMAGE_NAME=secrets-store-csi-driver-provider-aws

# Build for AMD64 and ARM64
ARCHITECTURES=arm64 amd64
GOOS=linux

MAJOR_REV=1
MINOR_REV=0
$(eval PATCH_REV=$(shell git describe --always))
$(eval BUILD_DATE=$(shell date -u +%Y.%m.%d.%H.%M))
FULL_REV=$(MAJOR_REV).$(MINOR_REV).$(PATCH_REV)-$(BUILD_DATE)

LDFLAGS?="-X github.com/aws/secrets-store-csi-driver-provider-aws/server.Version=$(FULL_REV) -extldflags "-static""

.PHONY: all build clean docker-login docker-buildx docker-manifest

# Build docker image and push to AWS registry
all: build docker-login docker-buildx docker-manifest

build: clean
	$(foreach ARCH,$(ARCHITECTURES),CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(ARCH) go build -a -ldflags $(LDFLAGS) -o _output/$(IMAGE_NAME)-$(ARCH) ;)

clean:
	-rm -rf _output
	-docker system prune --all --force

docker-login:
	aws --region $(AWS_REGION) $(ECRCMD) get-login-password | docker login -u AWS --password-stdin $(REPOBASE)

# Build, tag, and push image for architecture
docker-buildx:
	$(foreach ARCH,$(ARCHITECTURES),docker buildx build \
                --platform $(GOOS)/$(ARCH) \
                --no-cache \
                --push \
                -t $(REGISTRY_NAME):latest-$(ARCH) \
                -t $(REGISTRY_NAME):latest-$(GOOS)-$(ARCH) \
                -t $(REGISTRY_NAME):$(FULL_REV)-$(GOOS)-$(ARCH) \
                . ;)

# Create and push manifest list for images
docker-manifest:
	docker buildx imagetools create --tag $(REGISTRY_NAME):latest $(foreach ARCH, $(ARCHITECTURES), $(REGISTRY_NAME):latest-$(ARCH))
	docker buildx imagetools create --tag $(REGISTRY_NAME):$(FULL_REV) $(foreach ARCH, $(ARCHITECTURES), $(REGISTRY_NAME):latest-$(ARCH))
	docker buildx imagetools create --tag $(REGISTRY_NAME):$(MAJOR_REV) $(foreach ARCH, $(ARCHITECTURES), $(REGISTRY_NAME):latest-$(ARCH))

# Get a GitHub personal access token from the "Developer settings" section of your Github Account settings
upload-helm:
	chart-releaser package
	chart-releaser upload -o aws -r secrets-store-csi-driver-provider-aws --token $(GITHUB_TOKEN) --skip-existing
	chart-releaser index -o aws -r secrets-store-csi-driver-provider-aws --token $(GITHUB_TOKEN) --push --index-path .

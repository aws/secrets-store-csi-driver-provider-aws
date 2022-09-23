$(eval AWS_REGION=$(shell echo $${REGION:-us-east-1}))
$(eval REGISTRY_NAME=$(shell echo $${PRIVREPO:-public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws}))
$(eval REPOBASE=$(shell echo $(REGISTRY_NAME) | cut -f1 -d/))

ifeq ($(REPOBASE), public.ecr.aws)
ECRCMD=ecr-public
else
ECRCMD=ecr
endif

# Build for AMD64 and ARM64
ARCHITECTURES=arm64 amd64
GOOS=linux

MAJOR_REV=1
MINOR_REV=1
PATCH_REV=0
FULL_REV=$(MAJOR_REV).$(MINOR_REV).$(PATCH_REV)

.PHONY: all clean docker-login docker-buildx

# Build docker image and push to AWS registry
all: clean docker-login docker-buildx

clean:
	-rm -rf _output
	-docker system prune --all --force

docker-login:
	aws --region $(AWS_REGION) $(ECRCMD) get-login-password | docker login -u AWS --password-stdin $(REPOBASE)

# Build, tag, and push multi-architecture image.
docker-buildx:
	@!(docker manifest inspect $(REGISTRY_NAME):$(FULL_REV) > /dev/null) || (echo "Version already exists"; exit 1)

	docker buildx build --platform linux/arm64,linux/amd64 --push \
				-t $(REGISTRY_NAME):latest \
				-t $(REGISTRY_NAME):$(FULL_REV) \
				-t $(REGISTRY_NAME):$(MAJOR_REV) \
				-t $(REGISTRY_NAME):latest-linux \
				-t $(REGISTRY_NAME):latest-linux-amd64 \
				-t $(REGISTRY_NAME):latest-linux-arm64 \
				-t $(REGISTRY_NAME):$(FULL_REV)-linux-amd64 \
				-t $(REGISTRY_NAME):$(FULL_REV)-linux-arm64 \
				. ;

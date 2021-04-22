$(eval AWS_REGION=$(shell echo $${REGION:-us-east-1}))
$(eval REGISTRY_NAME=$(shell echo $${PRIVREPO:-public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws}))
$(eval REPOBASE=$(shell echo $(REGISTRY_NAME) | cut -f1 -d/))

ifeq ($(REPOBASE), "public.ecr.aws")
ECRCMD=ecr-public
else
ECRCMD=ecr
endif

IMAGE_NAME=secrets-store-csi-driver-provider-aws

GOOS=linux
GOARCH=amd64

BASE_REV=1.0
$(eval BUILD_DATE=$(shell date -u +%Y.%m.%d.%H.%M))
$(eval MINOR_REV=$(shell git describe --always))
REV=$(BASE_REV).$(MINOR_REV)-$(BUILD_DATE)

LDFLAGS?="-X github.com/aws/secrets-store-csi-driver-provider-aws/server.Version=$(REV) -extldflags "-static""

# Build docker image and push to AWS registry
all: build docker-login docker-build docker-tag docker-push

build: clean
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags ${LDFLAGS} -o _output/$(IMAGE_NAME)

clean:
	-rm -rf _output
	-docker system prune --all --force

docker-login:
	aws --region $(AWS_REGION) $(ECRCMD) get-login-password | docker login -u AWS --password-stdin $(REPOBASE)

# Build docker target
docker-build:
	docker build -f Dockerfile --no-cache -t $(IMAGE_NAME) .

# Tag docker image
docker-tag:
	docker tag $(IMAGE_NAME):latest $(REGISTRY_NAME):latest
	docker tag $(IMAGE_NAME):latest $(REGISTRY_NAME):latest-$(GOARCH)
	docker tag $(IMAGE_NAME):latest $(REGISTRY_NAME):latest-$(GOOS)-$(GOARCH)
	docker tag $(IMAGE_NAME):latest $(REGISTRY_NAME):$(REV)-$(GOOS)-$(GOARCH)

# Push to registry
docker-push:
	docker push $(REGISTRY_NAME):latest
	docker push $(REGISTRY_NAME):latest-$(GOARCH)
	docker push $(REGISTRY_NAME):latest-$(GOOS)-$(GOARCH)
	docker push $(REGISTRY_NAME):$(REV)-$(GOOS)-$(GOARCH)


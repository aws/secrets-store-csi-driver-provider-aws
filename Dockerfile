FROM --platform=$TARGETPLATFORM golang:1.18-alpine as go
ARG TARGETPLATFORM
ARG BUILDPLATFORM

RUN echo "Running on ${BUILDPLATFORM}, building for ${TARGETPLATFORM}."

WORKDIR /workdir
COPY go.mod .
COPY go.sum .

RUN apk add git build-base
RUN go env -w GOPROXY=direct
RUN go mod download -x

COPY . .

RUN go build -v -o _output/secrets-store-csi-driver-provider-aws

FROM --platform=$TARGETPLATFORM public.ecr.aws/amazonlinux/amazonlinux:2 as base
ARG TARGETPLATFORM

FROM scratch

COPY --from=go  /workdir/_output/secrets-store-csi-driver-provider-aws /bin/secrets-store-csi-driver-provider-aws

# Copy current certificates from AL2 (/etc/pki/ symlinked in /etc/ssl/certs/)
COPY --from=base /etc/pki/ /etc/pki/
COPY --from=base /etc/ssl/certs/ /etc/ssl/certs

ENTRYPOINT ["/bin/secrets-store-csi-driver-provider-aws"]

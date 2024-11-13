FROM golang:1.23-alpine AS go
ARG BUILDPLATFORM
ARG TARGETPLATFORM
WORKDIR /workdir

RUN echo "Running on ${BUILDPLATFORM}, building for ${TARGETPLATFORM}."
RUN apk add git build-base
RUN go env -w GOPROXY=direct

COPY go.mod .
COPY go.sum .

RUN go mod download -x

COPY . .

RUN go build -v -o _output/secrets-store-csi-driver-provider-aws

FROM public.ecr.aws/amazonlinux/amazonlinux:2 AS al2

FROM scratch

# Copy current certificates from AL2 (/etc/pki/ symlinked in /etc/ssl/certs/)
COPY --from=al2 /etc/pki/ /etc/pki/
COPY --from=al2 /etc/ssl/certs/ /etc/ssl/certs

COPY --from=go  /workdir/_output/secrets-store-csi-driver-provider-aws /bin/secrets-store-csi-driver-provider-aws

ENTRYPOINT ["/bin/secrets-store-csi-driver-provider-aws"]

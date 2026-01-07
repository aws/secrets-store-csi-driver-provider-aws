FROM public.ecr.aws/docker/library/golang:1.24-alpine AS go
ARG BUILDPLATFORM
ARG TARGETPLATFORM
RUN echo "Running on ${BUILDPLATFORM}, building for ${TARGETPLATFORM}."

WORKDIR /workdir

RUN apk add --no-cache git build-base ca-certificates
RUN update-ca-certificates || true
RUN go env -w GOPROXY=https://proxy.golang.org,direct

COPY go.mod .
COPY go.sum .

RUN go mod download -x

COPY . .

ENV CGO_ENABLED=0
ARG LDFLAGS
RUN go build -v -ldflags "${LDFLAGS}" -o _output/secrets-store-csi-driver-provider-aws

FROM public.ecr.aws/amazonlinux/amazonlinux:2 AS al2

FROM scratch

# Copy current certificates from AL2 (/etc/pki/ symlinked in /etc/ssl/certs/)
COPY --from=al2 /etc/pki/ /etc/pki/
COPY --from=al2 /etc/ssl/certs/ /etc/ssl/certs

COPY --from=go  /workdir/_output/secrets-store-csi-driver-provider-aws /bin/secrets-store-csi-driver-provider-aws

ENTRYPOINT ["/bin/secrets-store-csi-driver-provider-aws"]

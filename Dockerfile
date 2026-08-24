FROM public.ecr.aws/docker/library/golang:1.26-alpine AS go
ARG BUILDPLATFORM
ARG TARGETPLATFORM
RUN echo "Running on ${BUILDPLATFORM}, building for ${TARGETPLATFORM}."

WORKDIR /workdir

RUN apk add git build-base

# Override to `direct` on networks that cannot reach proxy.golang.org.
ARG GOPROXY=https://proxy.golang.org,direct
ENV GOPROXY=${GOPROXY}

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

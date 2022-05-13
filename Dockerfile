ARG ARCH
ARG MAJOR_REV
FROM golang:1.18-alpine as go

WORKDIR /workdir
COPY go.mod .
COPY go.sum .

RUN apk add git
RUN apk add build-base
RUN go env -w GOPROXY=direct
RUN go mod download

COPY . .

RUN go build -a -o _output/secrets-store-csi-driver-provider-aws-${ARCH}

FROM public.ecr.aws/amazonlinux/amazonlinux:2 as base

FROM scratch
ARG TARGETARCH
COPY --from=go  /workdir/_output/secrets-store-csi-driver-provider-aws-${ARCH} /bin/secrets-store-csi-driver-provider-aws

# Copy current certificates from AL2 (/etc/pki/ symlinked in /etc/ssl/certs/)
COPY --from=base /etc/pki/ /etc/pki/
COPY --from=base /etc/ssl/certs/ /etc/ssl/certs

ENTRYPOINT ["/bin/secrets-store-csi-driver-provider-aws"]

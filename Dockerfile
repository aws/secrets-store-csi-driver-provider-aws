FROM public.ecr.aws/docker/library/golang:1.17.6 AS build

ARG LDFLAGS
ENV GOPROXY=direct

RUN mkdir /build
WORKDIR /build
COPY . ./
RUN go mod download
RUN CGO_ENABLED=0 go build -a -ldflags "${LDFLAGS}" -o _output/secrets-store-csi-driver-provider-aws

# Copy current certificates from AL2
FROM public.ecr.aws/amazonlinux/amazonlinux:2 as certs
RUN cp -Lr /etc/ssl/certs/ /etc/ssl/certscopy

# Final image
FROM scratch
COPY --from=build /build/_output/secrets-store-csi-driver-provider-aws /bin/secrets-store-csi-driver-provider-aws
COPY --from=certs /etc/ssl/certscopy/ /etc/ssl/certs/

ENTRYPOINT ["/bin/secrets-store-csi-driver-provider-aws"]

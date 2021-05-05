# Copy current certificates from AL2
FROM public.ecr.aws/amazonlinux/amazonlinux:2 as base
RUN cp -Lr /etc/ssl/certs/ /etc/ssl/certscopy

FROM golang:1.16.3 AS build
WORKDIR /go/src/app
COPY . .
RUN make build
RUN ls -al

FROM scratch
COPY --from=build /go/src/app/_output/secrets-store-csi-driver-provider-aws /bin/
COPY --from=base /etc/ssl/certscopy/ /etc/ssl/certs/

ENTRYPOINT ["/bin/secrets-store-csi-driver-provider-aws"]

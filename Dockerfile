FROM public.ecr.aws/amazonlinux/amazonlinux:2 as base

FROM scratch
ARG TARGETARCH
COPY ./_output/secrets-store-csi-driver-provider-aws-${TARGETARCH} /bin/secrets-store-csi-driver-provider-aws

# Copy current certificates from AL2 (/etc/pki/ symlinked in /etc/ssl/certs/)
COPY --from=base /etc/pki/ /etc/pki/
COPY --from=base /etc/ssl/certs/ /etc/ssl/certs

ENTRYPOINT ["/bin/secrets-store-csi-driver-provider-aws"]

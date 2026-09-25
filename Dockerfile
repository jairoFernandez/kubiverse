# k8s-bridge for team mode: runs inside the cluster, serves the game at /.
# The web build must be in bridge/webdist first (make webdist, or the CI).
#   docker build -t kubiverse-bridge .
FROM --platform=$BUILDPLATFORM golang:1.27 AS build
ARG TARGETOS TARGETARCH
WORKDIR /src/bridge
COPY bridge/go.mod bridge/go.sum ./
RUN go mod download
COPY bridge/ ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/k8s-bridge .

# kubectl for the in-game terminal and the YAML editor, checksum-verified.
FROM --platform=$BUILDPLATFORM alpine:3.22 AS kubectl
ARG TARGETARCH
ARG KUBECTL_VERSION=v1.37.1
RUN apk add --no-cache curl && \
    curl -fsSLo /kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" && \
    echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256")  /kubectl" | sha256sum -c - && \
    chmod 0755 /kubectl

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/k8s-bridge /k8s-bridge
COPY --from=kubectl /kubectl /usr/local/bin/kubectl
# Kinds, audit log and settings live here (mount a volume to keep them).
VOLUME /data
EXPOSE 8088
USER nonroot:nonroot
ENTRYPOINT ["/k8s-bridge"]
CMD ["--in-cluster", "--addr", "0.0.0.0:8088", "--data", "/data/kubeconfigs"]

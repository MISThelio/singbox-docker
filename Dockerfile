ARG SING_BOX_VERSION=v1.13.14

FROM golang:1.25-alpine AS builder
ARG SING_BOX_VERSION
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch "${SING_BOX_VERSION}" https://github.com/SagerNet/sing-box.git .
RUN go build -tags "with_quic,with_utls" -trimpath -ldflags "-s -w -buildid=" -o /out/sing-box ./cmd/sing-box

FROM alpine:3.22
RUN apk add --no-cache ca-certificates tzdata
COPY --from=builder /out/sing-box /usr/local/bin/sing-box
VOLUME ["/etc/sing-box", "/var/lib/sing-box"]
ENTRYPOINT ["sing-box"]
CMD ["-D", "/var/lib/sing-box", "-C", "/etc/sing-box", "run"]

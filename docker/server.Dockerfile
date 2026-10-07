# Build context: <target>/clones/gochathub-server
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/gochathub-server ./cmd/chatserver

FROM alpine:3
# no ENTRYPOINT: compose passes full argv (sh -c migrate&&serve), ghc passes subcommands
COPY --from=build /out/gochathub-server /usr/local/bin/gochathub-server
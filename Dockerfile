FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /app/servidor ./cmd/api
FROM alpine:3.20
RUN addgroup -S ingressagroup && adduser -S -G ingressagroup -u 1000 ingressa
WORKDIR /app
RUN mkdir -p uploads && chown ingressa:ingressagroup uploads/ 
USER ingressa
COPY --from=builder /app/servidor .
COPY --from=builder /app/frontend ./frontend
EXPOSE 8080
CMD ["/app/servidor"]

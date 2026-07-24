FROM alpine:3.20
RUN apk add --no-cache curl
WORKDIR /app
COPY hello.sh .
RUN chmod +x hello.sh
CMD ["./hello.sh"]

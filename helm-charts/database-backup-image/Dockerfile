FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
RUN ln -snf /usr/share/zoneinfo/Europe/Paris /etc/localtime && echo "Europe/Paris" > /etc/timezone

RUN apt-get update && \
    apt-get install -y mongo-tools awscli && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]

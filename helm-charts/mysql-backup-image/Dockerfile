FROM ubuntu:20.04

# Désactiver l'interaction lors de l'installation des paquets
ENV DEBIAN_FRONTEND=noninteractive

# Configurer le fuseau horaire (optionnel)
RUN ln -snf /usr/share/zoneinfo/Europe/Paris /etc/localtime && echo "Europe/Paris" > /etc/timezone

# Installer le client MySQL et l'AWS CLI, et créer le répertoire /backup
RUN apt-get update && \
    apt-get install -y mysql-client awscli && \
    mkdir -p /backup && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]

FROM gitlab/gitlab-ee:latest AS  main

RUN mkdir -p /etc/gitlab-secrets \
         && mkdir -p /etc/gitlab-secrets/ssl \
         && chmod 755 /etc/gitlab-secrets/ssl

COPY ./gitlab_certs/gitlab.crt /etc/gitlab-secrets/ssl/gitlab.internal.crt
COPY ./gitlab_certs/gitlab.key /etc/gitlab-secrets/ssl/gitlab.internal.key
COPY ./gitlab_certs/ci_jwt.key /etc/gitlab-secrets/ci_jwt_signing_key.pem
COPY ./gitlab_certs/rootCA.crt /usr/local/share/ca-certificates/rootCA.crt

RUN chown root:root /etc/gitlab-secrets/ssl/gitlab.internal.* \
        && chmod 644 /etc/gitlab-secrets/ssl/gitlab.internal.crt \
        && chmod 640 /etc/gitlab-secrets/ssl/gitlab.internal.key \
        && update-ca-certificates --fresh

ENV GITLAB_OMNIBUS_CONFIG="\
external_url 'https://gitlab.internal'; \
letsencrypt['enable'] = false; \
nginx['ssl_certificate'] = '/etc/gitlab-secrets/ssl/gitlab.internal.crt'; \
nginx['ssl_certificate_key'] = '/etc/gitlab-secrets/ssl/gitlab.internal.key'; \
"

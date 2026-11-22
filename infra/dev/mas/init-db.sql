-- Creates the separate Postgres database for Matrix Authentication Service (MAS) in infra/dev/docker-compose.mas.yml.
CREATE DATABASE mas WITH ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE=template0;

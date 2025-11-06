# Multi-stage build for Data API Builder with baked-in configuration
# This eliminates the need for Azure File Share and storage accounts

# Stage 1: Validation stage with DAB CLI
FROM mcr.microsoft.com/dotnet/sdk:8.0-cbl-mariner2.0 AS build
WORKDIR /config

# Copy DAB configuration into the build stage
COPY dab-config.json .

# Install Data API Builder CLI for validation
RUN dotnet new tool-manifest
RUN dotnet tool install Microsoft.DataApiBuilder

# Validation removed: environment variables (like MSSQL_CONNECTION_STRING) do not exist at build time.
# Config will be validated post-deployment via `dab validate` job in Container Apps.

# Stage 2: Runtime image with baked configuration
FROM mcr.microsoft.com/azure-databases/data-api-builder:latest

# Copy validated configuration from build stage into /App directory
# DAB expects config at /App/dab-config.json by default
COPY --from=build /config/dab-config.json /App/dab-config.json

# Connection string will be injected as environment variable via Container Apps secrets
# No need for volume mounts or storage accounts

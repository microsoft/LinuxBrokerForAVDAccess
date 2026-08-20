FROM mcr.microsoft.com/azure-functions/python:4-python3.13

ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY task/requirements.txt /requirements.txt
RUN pip install --no-cache-dir -r /requirements.txt

COPY task/ /home/site/wwwroot

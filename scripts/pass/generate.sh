#!/bin/bash
echo "твой пароль: $(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*(){}[]_+=' | head -c 15)"

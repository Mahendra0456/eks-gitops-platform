#!/bin/bash
pkill -f "kubectl port-forward" || true
echo "Port-forwards stopped."

import http from 'k6/http';
import { sleep } from 'k6';

// Run:  docker run --rm -i -e TARGET=http://<app-elb-hostname> grafana/k6 run - < loadtest/k6.js
export const options = {
  stages: [
    { duration: '1m', target: 30 },
    { duration: '3m', target: 100 },
    { duration: '1m', target: 0 },
  ],
};

export default function () {
  http.get(`${__ENV.TARGET}/api/products`);
  sleep(0.05);
}

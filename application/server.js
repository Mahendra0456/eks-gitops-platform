const express = require('express');
const mongoose = require('mongoose');
const client = require('prom-client');
const path = require('path');

const PORT = process.env.PORT || 3000;
const MONGO_URI = process.env.MONGO_URI || 'mongodb://localhost:27017/shop';
const FAIL_RATE = parseFloat(process.env.FAIL_RATE || '0');

const log = (level, msg, extra = {}) =>
  console.log(JSON.stringify({ time: new Date().toISOString(), level, message: msg, ...extra }));

client.collectDefaultMetrics();
const httpCounter = new client.Counter({
  name: 'http_requests_total',
  help: 'HTTP requests',
  labelNames: ['method', 'status']
});

const Product = mongoose.model('Product', new mongoose.Schema({
  name: String, price: Number, image: String, stock: Number
}));
const Order = mongoose.model('Order', new mongoose.Schema({
  items: [{ productId: String, name: String, price: Number, qty: Number }],
  total: Number, customer: String, createdAt: { type: Date, default: Date.now }
}));

const app = express();
app.disable('x-powered-by');
app.use(express.json());

// count every response by status code (used by Prometheus and the canary analysis)
app.use((req, res, next) => {
  res.on('finish', () => httpCounter.inc({ method: req.method, status: res.statusCode }));
  next();
});

// one JSON log line per request (collected by Filebeat)
app.use((req, res, next) => {
  res.on('finish', () => log('info', `${req.method} ${req.originalUrl} ${res.statusCode}`));
  next();
});

// failure injection for the bad-release demo (FAIL_RATE=0 disables it)
app.use((req, res, next) => {
  if (FAIL_RATE > 0 && req.path.startsWith('/api') && Math.random() < FAIL_RATE) {
    log('error', 'Injected failure');
    return res.status(500).json({ error: 'injected' });
  }
  next();
});

app.use(express.static(path.join(__dirname, 'public')));

app.get('/health', (req, res) =>
  res.status(200).json({ status: 'ok', db: mongoose.connection.readyState === 1 ? 'up' : 'down' }));

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

app.get('/api/products', async (req, res) => {
  try {
    res.json(await Product.find().maxTimeMS(5000));
  } catch (e) {
    log('error', `Database connection timeout: ${e.message}`);
    res.status(500).json({ error: 'db error' });
  }
});

app.post('/api/orders', async (req, res) => {
  try {
    const { items = [], customer = 'guest' } = req.body;
    if (!items.length) return res.status(400).json({ error: 'empty cart' });
    const total = items.reduce((s, i) => s + i.price * i.qty, 0);
    const order = await Order.create({ items, total, customer });
    log('info', 'order created', { orderId: order._id, total });
    res.status(201).json(order);
  } catch (e) {
    log('error', `Order failed: ${e.message}`);
    res.status(500).json({ error: 'db error' });
  }
});

app.get('/api/orders', async (req, res) => {
  try {
    res.json(await Order.find().sort({ createdAt: -1 }).limit(20));
  } catch (e) {
    log('error', `Database error: ${e.message}`);
    res.status(500).json({ error: 'db error' });
  }
});

async function seed() {
  if (await Product.countDocuments() === 0) {
    await Product.insertMany([
      { name: 'Wireless Earbuds', price: 1499, image: '🎧', stock: 50 },
      { name: 'Smart Watch', price: 2999, image: '⌚', stock: 30 },
      { name: 'Backpack', price: 1299, image: '🎒', stock: 40 },
      { name: 'Running Shoes', price: 2499, image: '👟', stock: 25 },
      { name: 'Sunglasses', price: 799, image: '🕶️', stock: 60 },
      { name: 'Water Bottle', price: 399, image: '🍶', stock: 100 }
    ]);
    log('info', 'seeded products');
  }
}

async function connect() {
  try {
    await mongoose.connect(MONGO_URI, { serverSelectionTimeoutMS: 5000 });
    log('info', 'MongoDB connected');
    await seed();
  } catch (e) {
    log('error', `MongoDB connection failed, retrying in 5s: ${e.message}`);
    setTimeout(connect, 5000);
  }
}

app.listen(PORT, () => log('info', `ShopKart listening on ${PORT}`));
connect();

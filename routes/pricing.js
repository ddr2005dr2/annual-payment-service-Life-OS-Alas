const express = require('express');
const router = express.Router();
const fs = require('fs');
const path = require('path');

router.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, '..', 'public', 'pricing.html'));
});

router.get('/tiers', (req, res) => {
  const cfgPath = path.join(__dirname, '..', 'config', 'pricing-tiers.json');
  try {
    const raw = fs.readFileSync(cfgPath, 'utf8');
    res.json(JSON.parse(raw));
  } catch (e) {
    res.status(500).json({ error: 'Pricing configuration not available.' });
  }
});

module.exports = router;

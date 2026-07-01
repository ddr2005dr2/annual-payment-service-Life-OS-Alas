const express = require('express');
const path = require('path');
const fs = require('fs');
const router = express.Router();

router.get('/contexts', (req, res) => {
  const cfgPath = path.join(__dirname, '..', 'config', 'concierge-contexts.json');
  try {
    const raw = fs.readFileSync(cfgPath, 'utf8');
    res.json(JSON.parse(raw));
  } catch (e) {
    res.status(500).json({ error: 'Concierge contexts not available.' });
  }
});

module.exports = router;

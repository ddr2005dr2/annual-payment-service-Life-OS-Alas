const express = require('express');
const path = require('path');
const router = express.Router();

router.get('/privacy', (req, res) => {
  res.sendFile(path.join(__dirname, '..', 'public', 'legal', 'privacy.html'));
});

router.get('/terms', (req, res) => {
  res.sendFile(path.join(__dirname, '..', 'public', 'legal', 'terms.html'));
});

router.get('/ai', (req, res) => {
  res.sendFile(path.join(__dirname, '..', 'public', 'legal', 'ai.html'));
});

router.get('/data', (req, res) => {
  res.sendFile(path.join(__dirname, '..', 'public', 'legal', 'data.html'));
});

module.exports = router;

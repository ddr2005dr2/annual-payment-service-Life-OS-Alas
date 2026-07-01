const express = require('express');
const path = require('path');
const router = express.Router();

router.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, '..', 'public', 'onboarding.html'));
});

// Simple in-memory onboarding state for now
let onboardingState = {};

router.get('/state', (req, res) => {
  res.json(onboardingState);
});

router.post('/state', express.json(), (req, res) => {
  onboardingState = req.body || {};
  res.json({ ok: true });
});

module.exports = router;

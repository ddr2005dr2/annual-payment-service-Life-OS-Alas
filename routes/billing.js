const express = require('express');
const router = express.Router();

router.get('/', (req, res) => {
  res.json({ message: 'Billing API placeholder. Connect Stripe/Square in Phase 1.' });
});

module.exports = router;

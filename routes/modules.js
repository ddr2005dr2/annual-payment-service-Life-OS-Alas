const express = require('express');
const path = require('path');
const router = express.Router();

router.get('/:moduleId', (req, res) => {
  // For now, reuse dashboard shell
  res.sendFile(path.join(__dirname, '..', 'public', 'dashboard.html'));
});

module.exports = router;

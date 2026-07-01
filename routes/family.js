const express = require('express');
const router = express.Router();

// Minimal family stub
let familyState = {
  members: [],
  routines: []
};

router.get('/', (req, res) => {
  res.json(familyState);
});

router.post('/', express.json(), (req, res) => {
  familyState = req.body || familyState;
  res.json({ ok: true, state: familyState });
});

module.exports = router;

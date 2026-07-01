const express = require('express');
const path = require('path');
const router = express.Router();

router.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, '..', 'public', 'dashboard.html'));
});

// Placeholder dashboard data
router.get('/data', (req, res) => {
  res.json({
    todayMissions: [],
    modules: ['admin-autopilot','money-mission-control','health-navigator','family-coordination'],
    statuses: []
  });
});

module.exports = router;

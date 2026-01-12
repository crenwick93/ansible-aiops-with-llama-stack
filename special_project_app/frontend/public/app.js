const btn = document.getElementById('btn-pay');
const statusEl = document.getElementById('status');
const resultEl = document.getElementById('result');

async function pay() {
  statusEl.textContent = 'Processing...';
  statusEl.className = 'status';
  resultEl.textContent = '';
  try {
    const res = await fetch('/api/checkout', { method: 'POST' });
    const text = await res.text();
    if (res.ok) {
      statusEl.textContent = 'Payment success (demo)';
      statusEl.className = 'status ok';
    } else {
      statusEl.textContent = `Payment failed: HTTP ${res.status}`;
      statusEl.className = 'status err';
    }
    resultEl.textContent = text;
  } catch (e) {
    statusEl.textContent = 'Network error calling /api/checkout';
    statusEl.className = 'status err';
    resultEl.textContent = String(e);
  }
}

btn.addEventListener('click', pay);



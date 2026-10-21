// Assisto owner panel — tiny progressive enhancement (no framework, no eval).
(function () {
  "use strict";
  // Drag & drop reorder of the Discover table. Without JS the ↑/↓ buttons work.
  var table = document.getElementById("cards-table");
  var ids = document.getElementById("reorder-ids");
  var save = document.getElementById("reorder-save");
  if (table && ids && save) {
    var body = table.tBodies[0], dragging = null;
    body.addEventListener("dragstart", function (e) {
      dragging = e.target.closest("tr");
      if (!dragging) return;
      dragging.classList.add("dragging");
      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", dragging.dataset.id);
    });
    body.addEventListener("dragover", function (e) {
      var tr = e.target.closest("tr");
      if (!dragging || !tr || tr === dragging) return;
      e.preventDefault();
      var r = tr.getBoundingClientRect();
      body.insertBefore(dragging, (e.clientY - r.top) > r.height / 2 ? tr.nextSibling : tr);
    });
    body.addEventListener("dragend", function () {
      if (!dragging) return;
      dragging.classList.remove("dragging");
      dragging = null;
      var order = Array.prototype.map.call(body.rows, function (r) { return r.dataset.id; });
      if (order.join(",") !== ids.value) { ids.value = order.join(","); save.hidden = false; }
    });
  }
})();

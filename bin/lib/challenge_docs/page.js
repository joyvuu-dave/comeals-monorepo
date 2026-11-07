/* global document, window, location */
// The filters and search box of docs/challenges/challenges.html. bin/challenges
// puts this file into the page as text (bin/lib/challenge_docs/html.rb).
(function () {
  var status = "",
    area = "";
  var cards = Array.prototype.slice.call(
    document.querySelectorAll(".challenge"),
  );
  var search = document.getElementById("search");
  var shown = document.getElementById("shown");
  function update() {
    var words = search.value.toLowerCase().split(/\s+/).filter(Boolean);
    var count = 0;
    cards.forEach(function (card) {
      var text = card.textContent.toLowerCase();
      var show =
        (!status || card.dataset.status === status) &&
        (!area || card.dataset.area === area) &&
        words.every(function (word) {
          return text.indexOf(word) !== -1;
        });
      card.hidden = !show;
      if (show) count += 1;
    });
    shown.textContent = "Showing " + count + " of " + cards.length + ".";
  }
  function group(id, set) {
    var buttons = document.querySelectorAll("#" + id + " button");
    buttons.forEach(function (button) {
      button.addEventListener("click", function () {
        buttons.forEach(function (other) {
          other.classList.toggle("on", other === button);
        });
        set(
          button.dataset.status !== undefined
            ? button.dataset.status
            : button.dataset.area,
        );
        update();
      });
    });
  }
  group("status-filter", function (value) {
    status = value;
  });
  group("area-filter", function (value) {
    area = value;
  });
  search.addEventListener("input", update);
  function openTarget() {
    var card = document.getElementById(location.hash.slice(1));
    if (card && card.tagName === "DETAILS") card.open = true;
  }
  window.addEventListener("hashchange", openTarget);
  openTarget();
  update();
})();

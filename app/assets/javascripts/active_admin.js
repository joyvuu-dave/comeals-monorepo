//= require active_admin/base

$(function() {
  // Equivalent of moment's 'ddd, MMM D YYYY' — produces e.g. "Wed, Mar 5 2025".
  function formatMealDate(d) {
    var weekday = d.toLocaleDateString('en-US', { weekday: 'short' });
    var month   = d.toLocaleDateString('en-US', { month: 'short' });
    return weekday + ', ' + month + ' ' + d.getDate() + ' ' + d.getFullYear();
  }

  // Format day of week on Meal index page
  $('td.col-date').each(function() {
    if ($(this).text()) {
      $(this).text(formatMealDate(new Date($(this).text())));
    }
  });

  // Format day of week on Bill index page
  $('td.col-meal').each(function() {
    if ($(this).text()) {
      $(this).text(formatMealDate(new Date($(this).text())));
    }
  });

  // Add day of week to options on Bill edit page
  $('#bill_meal_id option').each(function() {
    if ($(this).text()) {
      var d = new Date($(this).text());
      d.setDate(d.getDate() + 1);
      $(this).text(formatMealDate(d));
    }
  });

  // Bring name field into focus when adding a new unit
  if (window.location.pathname === '/units/new') {
    $('#unit_name').focus();
  }

  // Bring name field into focus when adding a new resident
  if (window.location.pathname === '/residents/new') {
    $('#resident_name').focus();
  }

  // Clear bill amount if it's 0
  if ($('#bill_amount_decimal').val() === '0.0') {
    $('#bill_amount_decimal').val('');
  }

  // Make the damn remember me checkbox default checked
  $('#admin_user_remember_me').prop('checked', true);

  // Change Communities to Community
  if ($("#page_title").html() === "Communities") {
    $("#page_title").html("Community");
  }

  // Make Date columns a little wider
  $('.col-date').css('min-width', '150px');

  // Let People Know This is the Admin Page
  if (window.location.pathname === "/login") {
    $("body").prepend("<h3 style='margin-left:auto;margin-right:auto;width:150px'>Admin Login</h3>");
    $("body").prepend("<a href='https://comeals.com'>User Login</a>");
  }
});

import toastStore from "../stores/toast_store";

// What a person sees when the server answered with an error but sent no
// message we can show. Only the errors ApiController rescues carry a
// message (api_controller.rb). Any other exception gets Rails' own page
// (public/500.html), and a Heroku router error gets Heroku's page, so
// response.data is HTML or has no `message`.
var SERVER_PROBLEM = "The server had a problem. Please try again.";

// Where a message goes when the caller names no other place: the stack
// of messages. Hands back the message's id.
function showInStack(message, type) {
  return toastStore.show(message, type);
}

// Show a failed request to the person, or only log it when
// `options.silent` is true. The message goes on top of the stack of
// messages, and its id is handed back. A calendar form passes
// `options.show`, its own way to show a message inside the form
// (use_form_messages.ts), and the message goes there instead (#137).
// Hands back what `show` hands back, or null when silent.
export default function handleAxiosError(error, options) {
  var silent = options && options.silent;
  var show = (options && options.show) || showInStack;
  if (error.response) {
    var data = error.response.data;
    if (data && data.message) {
      if (silent) {
        console.error(data.message);
        return null;
      }
      return show(data.message, "error");
    } else {
      console.error("Bad response from server", error);
      if (silent) return null;
      return show(SERVER_PROBLEM, "error");
    }
  } else if (error.request) {
    if (silent) {
      console.error("Error: no response received from server.");
      return null;
    }
    return show("Error: no response received from server.", "error");
  } else {
    if (silent) {
      console.error("Error: could not submit form.");
      return null;
    }
    return show("Error: could not submit form.", "error");
  }
}

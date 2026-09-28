import toastStore from "../stores/toast_store";

// What a person sees when the server answered with an error but sent no
// message we can show. Only the errors ApiController rescues carry a
// message (api_controller.rb). Any other exception gets Rails' own page
// (public/500.html), and a Heroku router error gets Heroku's page, so
// response.data is HTML or has no `message`.
var SERVER_PROBLEM = "The server had a problem. Please try again.";

export default function handleAxiosError(error, options) {
  var silent = options && options.silent;
  if (error.response) {
    var data = error.response.data;
    if (data && data.message) {
      var toastType = data.type === "warning" ? "warning" : "error";
      if (silent) {
        console.error(data.message);
      } else {
        toastStore.replaceAll(data.message, toastType);
      }
      return toastType;
    } else {
      console.error("Bad response from server", error);
      if (!silent) {
        toastStore.replaceAll(SERVER_PROBLEM, "error");
      }
      return "error";
    }
  } else if (error.request) {
    if (silent) {
      console.error("Error: no response received from server.");
    } else {
      toastStore.replaceAll(
        "Error: no response received from server.",
        "error",
      );
    }
    return "error";
  } else {
    if (silent) {
      console.error("Error: could not submit form.");
    } else {
      toastStore.replaceAll("Error: could not submit form.", "error");
    }
    return "error";
  }
}

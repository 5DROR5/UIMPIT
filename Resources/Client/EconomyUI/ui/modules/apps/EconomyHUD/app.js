// This file uses AngularJS to control the Economy HUD's behavior.
// It manages the UI's state, handles user input, and communicates with the Lua layer.

angular.module('beamng.apps')
.directive('economyHud', [function () {
  return {
    replace: true, // Replace the <economy-hud> element with the template
    templateUrl: '/ui/modules/apps/EconomyHUD/app.html', // Path to the HTML file for the UI
    restrict: 'EA', // Can be used as an Element ('E') or Attribute ('A')
    scope: true, // Create a new scope for this directive
    controller: ['$scope', '$http', function ($scope, $http) {

      // =======================================================================
      // || SCOPE VARIABLES - The data model for the UI                       ||
      // =======================================================================

      // The player's current money balance.
      $scope.balance = 0;
      // Boolean flags to control the visibility of UI panels.
      $scope.isUIOpen = false;
      $scope.isLangOpen = false;

      // An object to hold all display text. This makes localization easier.
      $scope.text = {
        open_ui: "💰 Open",
        close_ui: "❌ Close",
        balance_title: "Balance",
        currency_symbol: "$",
        language_label: "Language",
        // Flags for the language selection menu.
        language_flags: {
          en: '🇺🇸',
          he: '🇮🇱',
          ar: '🇸🇦',
        }
      };

      // The currently selected language code.
      $scope.selectedLang = 'en';

      // =======================================================================
      // || UI FUNCTIONS - Functions triggered by user actions (ng-click)     ||
      // =======================================================================

      // Toggles the main UI panel's visibility.
      $scope.toggleUI = function() { $scope.isUIOpen = !$scope.isUIOpen; };

      // Toggles the language selection menu's visibility.
      $scope.toggleLangMenu = function() { $scope.isLangOpen = !$scope.isLangOpen; };

      // Loads translation strings from a JSON file for the given language.
      function loadTranslations(langCode) {
        // Normalize the language code (e.g., 'en-US' becomes 'en').
        const lang = (langCode||'en').substring(0,2);
        const path = `/ui/modules/apps/EconomyHUD/translations/${lang}.json`;

        // Use AngularJS's $http service to fetch the JSON file.
        $http.get(path).then(
          // Success callback
          res => {
            // Merge the loaded translations with the existing text object.
            $scope.text = {...$scope.text, ...res.data};
            
            // Set text direction for Right-to-Left (RTL) languages like Hebrew and Arabic.
            const appContainer = document.getElementById('economy-hud-container');
            if (appContainer) {
                if(lang === 'he' || lang === 'ar'){
                    appContainer.dir = 'rtl'; // Set direction to Right-to-Left
                } else {
                    appContainer.dir = 'ltr'; // Set direction to Left-to-Right
                }
            }
          },
          // Error callback (e.g., translation file not found)
          () => {
            // Fallback to loading the English translations if the requested language fails.
            $http.get(`/ui/modules/apps/EconomyHUD/translations/en.json`).then(r=>{
              $scope.text = {...$scope.text, ...r.data};
              // Ensure direction is LTR on fallback.
              const appContainer = document.getElementById('economy-hud-container');
              if (appContainer) {
                appContainer.dir = 'ltr';
              }
            });
          }
        );
      }

      // Sets the player's language. Called when a language flag is clicked.
      $scope.setLanguage = function(langCode) {
        $scope.selectedLang = langCode;
        loadTranslations(langCode); // Update the UI text.
        $scope.isLangOpen = false; // Close the language menu.
        
        // Save the user's preference in the browser's local storage for persistence.
        localStorage.setItem('economyUiLang', langCode);
        
        // Call the Lua function in `key.lua` to notify the server of the change.
        bngApi.engineLua('setPlayerLanguage("' + langCode + '")');
      };

      // =======================================================================
      // || INITIALIZATION & EVENT LISTENERS                                  ||
      // =======================================================================

      // On startup, try to load the language saved in local storage.
      // If not found, default to the browser's language or English.
      let savedLang = localStorage.getItem('economyUiLang');
      let initialLang = savedLang || (window.navigator.language || 'en').substring(0,2);
      $scope.selectedLang = initialLang;
      loadTranslations($scope.selectedLang); // Load the initial translations.

      // Listen for the 'EconomyUI_Update' event from the Lua layer (`key.lua`).
      // This is the primary way the UI receives money updates from the server.
      $scope.$on('EconomyUI_Update', (e,data) => {
        // Parse the money value from the data payload.
        let money = (typeof data==='number')?data:(data && data.money!==undefined?data.money:null);
        if(money!==null) {
            // Use $applyAsync to safely update the scope from outside the Angular digest cycle.
            $scope.$applyAsync(()=>{$scope.balance=money;});
        }
      });

      // An alternative listener using the global `guihooks` object for compatibility.
      if(typeof guihooks!=='undefined'){
        guihooks.on("EconomyUI_Update", data => {
          let money = (data && data.money!==undefined)?data.money:data;
          if(money!==null) $scope.$applyAsync(()=>{$scope.balance=money;});
        });
      }
    }]
  };
}]);

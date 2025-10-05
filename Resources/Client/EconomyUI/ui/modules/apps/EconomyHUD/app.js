angular.module('beamng.apps')
.directive('economyHud', function() {
  return {
    restrict: 'E',
    templateUrl: '/ui/modules/apps/EconomyHUD/app.html',
    replace: true,
    controller: function($scope, $http) {
      $scope.isUIOpen = false;
      $scope.isLangOpen = false;
      $scope.balance = 0;
      $scope.wantedTime = 0;
      $scope.selectedLang = 'en';
      
      $scope.text = {
        open_ui: "Open UI",
        close_ui: "Close UI",
        balance_title: "Balance",
        currency_symbol: "$",
        wanted_label: "WANTED",
        language_label: "Language",
        language_flags: { en: "🇺🇸", he: "🇮🇱", ar: "🇸🇦" }
      };

      function loadTranslations(langCode) {
        const lang = (langCode||'en').substring(0,2);
        const path = `/ui/modules/apps/EconomyHUD/translations/${lang}.json`;
        
        $scope.selectedLang = lang;

        $http.get(path).then(
          res => {
            $scope.text = {...$scope.text, ...res.data};
            
            const appContainer = document.getElementById('economy-hud-container');
            if (appContainer) {
                if(lang === 'he' || lang === 'ar'){
                    appContainer.dir = 'rtl'; 
                } else {
                    appContainer.dir = 'ltr'; 
                }
            }
          },
          () => {
            $http.get(`/ui/modules/apps/EconomyHUD/translations/en.json`).then(r=>{
              $scope.text = {...$scope.text, ...r.data};
              const appContainer = document.getElementById('economy-hud-container');
              if (appContainer) {
                appContainer.dir = 'ltr';
              }
              $scope.selectedLang = 'en';
            });
          }
        );
      } 

      $scope.formatTime = function(totalSeconds) {
          if (totalSeconds <= 0) return '00:00';
          const minutes = Math.floor(totalSeconds / 60);
          const seconds = totalSeconds % 60;
          
          const pad = (num) => num.toString().padStart(2, '0');
          
          return `${pad(minutes)}:${pad(seconds)}`;
      };

      $scope.toggleUI = function() {
        $scope.$applyAsync(function() {
          $scope.isUIOpen = !$scope.isUIOpen;
        });
      };
      
      $scope.toggleLangMenu = function() {
        $scope.$applyAsync(function() {
          $scope.isLangOpen = !$scope.isLangOpen;
        });
      };
      
      $scope.setLanguage = (lang) => {
        if (window.bngApi && typeof window.bngApi.engineLua === 'function') {
          window.bngApi.engineLua(`setPlayerLanguage('${lang}')`);
          loadTranslations(lang); 
          $scope.$applyAsync(() => {
            $scope.isLangOpen = false;
          });
        } else {
          console.error("[EconomyHUD] bngApi is not available to set language.");
          loadTranslations(lang); 
        }
      };
      
      loadTranslations();


      $scope.$on('EconomyUI_Update', (e, data) => {
        console.log("[EconomyHUD] EconomyUI_Update", data);
        if (data && data.money !== undefined) {
          $scope.$applyAsync(() => { $scope.balance = data.money; });
        }
      });


      
      function handleWantedPayload(payload) {
        let wantedSeconds = null;
        try {
          if (payload && typeof payload === 'object' && payload.wantedTime != null) {
            wantedSeconds = Number(payload.wantedTime);
          }
        } catch (ex) {
          console.warn("[EconomyHUD] error parsing wanted payload", ex);
        }

        if (wantedSeconds != null && !isNaN(wantedSeconds)) {
          wantedSeconds = Math.max(0, Math.floor(wantedSeconds));
          $scope.$applyAsync(() => { $scope.wantedTime = wantedSeconds; });
        } else {
           console.warn("[EconomyHUD] Invalid or missing wantedTime in payload", payload);
        }
      }

      $scope.$on('EconomyUI_WantedUpdate', (e, payload) => {
        console.log("[EconomyHUD] Angular event 'EconomyUI_WantedUpdate' received:", payload);
        handleWantedPayload(payload);
      });

      try {
        if (typeof guihooks !== "undefined" && guihooks.on) {
          guihooks.on("EconomyUI_WantedUpdate", (data) => {
            console.log("[EconomyHUD] guihooks 'EconomyUI_WantedUpdate' received:", data);
            handleWantedPayload(data);
          });
        } else {
          console.warn("[EconomyHUD] guihooks not available in UI context. Relying on Angular event fallback.");
        }
      } catch (err) {
        console.error("[EconomyHUD] Error attaching guihooks listener:", err);
      }
    }
  };
});

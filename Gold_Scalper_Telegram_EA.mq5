//+------------------------------------------------------------------+
//|                   Gold_Scalper_Telegram_EA.mq5                    |
//|  Gold (XAUUSD) scalping/averaging EA with basket-based stop loss  |
//|  + full Telegram bot integration (buttons, news, stats).          |
//|                                                                    |
//|  BUG FIX vs previous version:                                     |
//|   - CopyBuffer() returns data indexed from PRESENT to PAST        |
//|     (index 0 = current forming bar, index 1 = last closed bar).   |
//|     The previous version had this reversed, causing incorrect/    |
//|     delayed crossover detection. Fixed below.                     |
//|                                                                    |
//|  REQUIRED SETUP:                                                  |
//|   1. Tools -> Options -> Expert Advisors -> check "Allow          |
//|      WebRequest for listed URL" and add: https://api.telegram.org |
//|   2. Attach this EA to an XAUUSD (Gold) chart only.               |
//|   3. Test on a DEMO account first. No profit is guaranteed.       |
//|                                                                    |
//|  RISK WARNING: This EA uses position averaging (adds trades in    |
//|  the same direction when price moves against it) with a basket-   |
//|  level floating loss cap. This bounds INTENDED risk but slippage  |
//|  during fast moves (common in gold, especially around news) can   |
//|  cause actual losses to exceed the configured cap.                |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//====================== INPUTS ======================================
input group "=== Telegram Bot ==="
input string   TelegramToken      = "8797767210:AAGPWz7AH_H6V9XqLyjisHn9q_DggUnFY-4"; // Bot token
input long     OwnerChatID        = 6603754497;    // Your Telegram chat ID (only this ID can control the bot)
input int      PollingIntervalSec = 4;              // How often to check for button presses (seconds)

input group "=== Symbol Safety ==="
input string   GoldSymbolFilter   = "XAU";

input group "=== Entry Signal (MA + RSI) ==="
input int      FastMA_Period      = 5;
input int      SlowMA_Period      = 20;
input ENUM_MA_METHOD MA_Method    = MODE_EMA;
input int      RSI_Period         = 14;
input double   RSI_Overbought     = 70.0;
input double   RSI_Oversold       = 30.0;

input group "=== Lot & Averaging ==="
input double   LotSize                 = 0.01;
input int      MaxOpenTrades           = 5;
input int      AveragingDistancePoints = 300;

input group "=== Profit & Basket Loss Cap ==="
input double   IndividualTP_USD    = 0.50;
input double   LossPerTradeUSD     = 10.0;

input group "=== Trade Filters ==="
input int      MagicNumber         = 202608;
input int      MaxSpread_Points    = 50;

input group "=== News Settings ==="
input int      NewsLookaheadMinutes = 60;   // Alert this many minutes before high-impact news
input int      NewsPauseBeforeMin   = 15;   // Stop opening NEW trades this many minutes before news
input int      NewsPauseAfterMin    = 15;   // Resume trading this many minutes after news

//====================== GLOBALS ======================================
int fastMA_handle, slowMA_handle, rsi_handle;
string GV_PREFIX;   // unique global-variable prefix per magic number
long   lastUpdateId = 0;
long   knownTickets[];              // tracks open tickets to detect new opens/closes
long   notifiedNewsIds[];           // event ids already alerted this session

bool g_startupEntryDone = false;   // NEW: يضمن دخول صفقة فورية أول ما يشتغل البوت (حسب طلب المستخدم)

// Toggle states (persisted via GlobalVariable so they survive EA restart)
bool NotifyTrades = true;
bool NotifyNews    = true;
bool NotifyDaily   = true;
bool NotifyWeekly  = true;

//+------------------------------------------------------------------+
//| UTF-8 URL ENCODE (needed for Arabic text in HTTP requests)        |
//+------------------------------------------------------------------+
string UrlEncode(string text)
{
   uchar utf8[];
   int len = StringToCharArray(text, utf8, 0, -1, CP_UTF8);
   string result = "";
   for(int i = 0; i < len - 1; i++) // last byte is null terminator
   {
      uchar c = utf8[i];
      if((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
         c == '-' || c == '_' || c == '.' || c == '~')
         result += CharToString((uchar)c);
      else
         result += StringFormat("%%%02X", c);
   }
   return result;
}

//+------------------------------------------------------------------+
//| Minimal JSON helpers (Telegram responses have predictable shape)  |
//+------------------------------------------------------------------+
string JsonGetString(string json, string key, int fromPos = 0)
{
   string pattern = "\"" + key + "\":\"";
   int p = StringFind(json, pattern, fromPos);
   if(p < 0) return "";
   p += StringLen(pattern);
   int e = p;
   while(e < StringLen(json))
   {
      if(StringGetCharacter(json, e) == '"' && StringGetCharacter(json, e - 1) != '\\') break;
      e++;
   }
   return StringSubstr(json, p, e - p);
}

long JsonGetNumber(string json, string key, int fromPos = 0)
{
   string pattern = "\"" + key + "\":";
   int p = StringFind(json, pattern, fromPos);
   if(p < 0) return -1;
   p += StringLen(pattern);
   int e = p;
   while(e < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, e);
      if((ch < '0' || ch > '9') && ch != '-') break;
      e++;
   }
   string numStr = StringSubstr(json, p, e - p);
   return StringToInteger(numStr);
}

//+------------------------------------------------------------------+
//| Send a Telegram message, optionally with an inline keyboard       |
//+------------------------------------------------------------------+
bool TelegramSend(string text, string replyMarkupJson = "")
{
   string url = "https://api.telegram.org/bot" + TelegramToken + "/sendMessage";
   string body = "chat_id=" + IntegerToString(OwnerChatID) +
                 "&text=" + UrlEncode(text) +
                 "&parse_mode=HTML";
   if(replyMarkupJson != "")
      body += "&reply_markup=" + UrlEncode(replyMarkupJson);

   char postData[];
   int len = StringToCharArray(body, postData, 0, -1, CP_UTF8) - 1;
   ArrayResize(postData, len);

   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   int res = WebRequest("POST", url, headers, 5000, postData, result, resultHeaders);
   if(res == -1)
   {
      int err = GetLastError();
      Print("Telegram WebRequest FAILED. Error: ", err,
            " -- Did you add https://api.telegram.org to Allow WebRequest list?");
      return false;
   }
   return true;
}

void TelegramAnswerCallback(string callbackId, string text)
{
   string url = "https://api.telegram.org/bot" + TelegramToken + "/answerCallbackQuery";
   string body = "callback_query_id=" + callbackId + "&text=" + UrlEncode(text);
   char postData[];
   int len = StringToCharArray(body, postData, 0, -1, CP_UTF8) - 1;
   ArrayResize(postData, len);
   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   WebRequest("POST", url, headers, 5000, postData, result, resultHeaders);
}

//+------------------------------------------------------------------+
//| Build the main menu keyboard reflecting current toggle states     |
//+------------------------------------------------------------------+
string BuildMenuJson()
{
   string t1 = NotifyNews   ? "✅" : "❌";
   string t2 = NotifyTrades ? "✅" : "❌";
   string t3 = NotifyDaily  ? "✅" : "❌";
   string t4 = NotifyWeekly ? "✅" : "❌";

   string json = "{\"inline_keyboard\":[" +
      "[{\"text\":\"🗞 اشعارات الأخبار " + t1 + "\",\"callback_data\":\"toggle_news\"}]," +
      "[{\"text\":\"📈 اشعارات الصفقات " + t2 + "\",\"callback_data\":\"toggle_trades\"}]," +
      "[{\"text\":\"📊 تقرير يومي تلقائي " + t3 + "\",\"callback_data\":\"toggle_daily\"}]," +
      "[{\"text\":\"📅 تقرير اسبوعي تلقائي " + t4 + "\",\"callback_data\":\"toggle_weekly\"}]," +
      "[{\"text\":\"📥 احصائية اليوم الآن\",\"callback_data\":\"stats_daily_now\"}," +
        "{\"text\":\"📥 احصائية الأسبوع الآن\",\"callback_data\":\"stats_weekly_now\"}]," +
      "[{\"text\":\"🔄 تحديث القائمة\",\"callback_data\":\"refresh_menu\"}]" +
      "]}";
   return json;
}

void SendMainMenu(string headerText = "⚙️ لوحة تحكم بوت الذهب:")
{
   TelegramSend(headerText, BuildMenuJson());
}

//+------------------------------------------------------------------+
//| Persisted toggle settings via GlobalVariable                      |
//+------------------------------------------------------------------+
void LoadSettings()
{
   GV_PREFIX = "GST_" + IntegerToString(MagicNumber) + "_";
   NotifyTrades = GlobalVariableCheck(GV_PREFIX + "Trades") ? (GlobalVariableGet(GV_PREFIX + "Trades") != 0) : true;
   NotifyNews   = GlobalVariableCheck(GV_PREFIX + "News")   ? (GlobalVariableGet(GV_PREFIX + "News") != 0)   : true;
   NotifyDaily  = GlobalVariableCheck(GV_PREFIX + "Daily")  ? (GlobalVariableGet(GV_PREFIX + "Daily") != 0)  : true;
   NotifyWeekly = GlobalVariableCheck(GV_PREFIX + "Weekly") ? (GlobalVariableGet(GV_PREFIX + "Weekly") != 0) : true;
   lastUpdateId = GlobalVariableCheck(GV_PREFIX + "LastUpdateId") ? (long)GlobalVariableGet(GV_PREFIX + "LastUpdateId") : 0;
}

void SaveToggle(string key, bool value)
{
   GlobalVariableSet(GV_PREFIX + key, value ? 1.0 : 0.0);
}

// BUG FIX: silently register already-open positions on EA startup so they
// aren't mistakenly reported as "new trades" the moment the EA (re)loads.
void InitKnownTickets()
{
   ArrayFree(knownTickets);
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         ArrayResize(knownTickets, n + 1);
         knownTickets[n] = (long)ticket;
         n++;
      }
   }
}

//+------------------------------------------------------------------+
//| Handle one incoming Telegram update (callback button press)       |
//+------------------------------------------------------------------+
void HandleUpdate(string updateJson)
{
   // Look specifically inside "from":{"id":...} to find the Telegram user who pressed the button
   int fromPos = StringFind(updateJson, "\"from\":{");
   long senderId = (fromPos >= 0) ? JsonGetNumber(updateJson, "id", fromPos) : -1;

   if(senderId != OwnerChatID)
      return; // security: ignore anyone who isn't the owner

   string callbackId = JsonGetString(updateJson, "id"); // callback_query id (string form)
   string data = JsonGetString(updateJson, "data");

   if(data == "") 
   {
      // Might be a plain text command like /start
      string msgText = JsonGetString(updateJson, "text");
      if(msgText == "/start" || msgText == "/menu")
         SendMainMenu("👋 أهلاً! هذا بوت التحكم بإشعارات إكسبيرت الذهب.");
      return;
   }

   string feedback = "";
   if(data == "toggle_news")    { NotifyNews    = !NotifyNews;    SaveToggle("News", NotifyNews);       feedback = NotifyNews ? "تم تفعيل اشعارات الأخبار" : "تم إيقاف اشعارات الأخبار"; }
   else if(data == "toggle_trades") { NotifyTrades = !NotifyTrades; SaveToggle("Trades", NotifyTrades); feedback = NotifyTrades ? "تم تفعيل اشعارات الصفقات" : "تم إيقاف اشعارات الصفقات"; }
   else if(data == "toggle_daily")  { NotifyDaily  = !NotifyDaily;  SaveToggle("Daily", NotifyDaily);   feedback = NotifyDaily ? "تم تفعيل التقرير اليومي" : "تم إيقاف التقرير اليومي"; }
   else if(data == "toggle_weekly") { NotifyWeekly = !NotifyWeekly; SaveToggle("Weekly", NotifyWeekly); feedback = NotifyWeekly ? "تم تفعيل التقرير الأسبوعي" : "تم إيقاف التقرير الأسبوعي"; }
   else if(data == "stats_daily_now")  { TelegramAnswerCallback(callbackId, "جاري إرسال إحصائية اليوم..."); SendStatsReport(1); return; }
   else if(data == "stats_weekly_now") { TelegramAnswerCallback(callbackId, "جاري إرسال إحصائية الأسبوع..."); SendStatsReport(7); return; }
   else if(data == "refresh_menu")     { TelegramAnswerCallback(callbackId, "تم التحديث"); SendMainMenu(); return; }

   TelegramAnswerCallback(callbackId, feedback);
   SendMainMenu(); // resend menu with updated checkmarks
}

//+------------------------------------------------------------------+
//| Poll Telegram for new updates (button presses / commands)         |
//+------------------------------------------------------------------+
void PollTelegramUpdates()
{
   string url = "https://api.telegram.org/bot" + TelegramToken + "/getUpdates?offset=" +
                IntegerToString(lastUpdateId + 1) + "&timeout=0";
   char postData[];
   char result[];
   string resultHeaders;
   string headers = "";

   int res = WebRequest("GET", url, headers, 5000, postData, result, resultHeaders);
   if(res == -1) return; // silently skip; TelegramSend already logs setup errors elsewhere

   string json = CharArrayToString(result, 0, -1, CP_UTF8);

   // Split by "update_id" occurrences and process each update block
   int firstMarker = StringFind(json, "\"update_id\":");
   if(firstMarker < 0) return;

   // Collect all start positions of update blocks
   int positions[]; ArrayResize(positions, 0);
   int searchFrom = 0;
   while(true)
   {
      int idx = StringFind(json, "\"update_id\":", searchFrom);
      if(idx < 0) break;
      int n = ArraySize(positions);
      ArrayResize(positions, n + 1);
      positions[n] = idx;
      searchFrom = idx + 1;
   }

   for(int i = 0; i < ArraySize(positions); i++)
   {
      int blockStart = positions[i];
      int blockEnd = (i + 1 < ArraySize(positions)) ? positions[i + 1] : StringLen(json);
      string block = StringSubstr(json, blockStart, blockEnd - blockStart);

      long updId = JsonGetNumber(block, "update_id");
      if(updId > lastUpdateId)
      {
         lastUpdateId = updId;
         GlobalVariableSet(GV_PREFIX + "LastUpdateId", (double)lastUpdateId);
      }
      HandleUpdate(block);
   }
}

//+------------------------------------------------------------------+
//| TRADE NOTIFICATIONS: detect newly opened / closed positions       |
//+------------------------------------------------------------------+
void CheckTradeNotifications()
{
   long currentTickets[];
   int count = 0;
   ArrayResize(currentTickets, 0);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ArrayResize(currentTickets, count + 1);
      currentTickets[count] = (long)ticket;
      count++;

      // Was this ticket already known? if not -> it's a NEW trade
      bool known = false;
      for(int k = 0; k < ArraySize(knownTickets); k++)
         if(knownTickets[k] == (long)ticket) { known = true; break; }

      if(!known && NotifyTrades)
      {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double volume     = PositionGetDouble(POSITION_VOLUME);
         long type = PositionGetInteger(POSITION_TYPE);
         string dirText = (type == POSITION_TYPE_BUY) ? "🟢 شراء" : "🔴 بيع";
         double balance = AccountInfoDouble(ACCOUNT_BALANCE);
         double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
         string msg = "📌 صفقة جديدة مفتوحة\n" +
                      "النوع: " + dirText + "\n" +
                      "اللوت: " + DoubleToString(volume, 2) + "\n" +
                      "سعر الدخول: " + DoubleToString(openPrice, _Digits) + "\n" +
                      "عدد الصفقات المفتوحة حالياً: " + IntegerToString(count) + "\n\n" +
                      "💰 رصيد الحساب (Balance): " + DoubleToString(balance, 2) + "$\n" +
                      "📊 الرصيد الحقيقي (Equity): " + DoubleToString(equity, 2) + "$";
         TelegramSend(msg);
      }
   }

   // Any ticket in knownTickets that's no longer open -> it CLOSED
   if(NotifyTrades)
   {
      for(int k = 0; k < ArraySize(knownTickets); k++)
      {
         long oldTicket = knownTickets[k];
         bool stillOpen = false;
         for(int c = 0; c < ArraySize(currentTickets); c++)
            if(currentTickets[c] == oldTicket) { stillOpen = true; break; }

         if(!stillOpen)
         {
            double profit = 0;
            if(HistorySelectByPosition(oldTicket))
            {
               int deals = HistoryDealsTotal();
               for(int d = 0; d < deals; d++)
               {
                  ulong dealTicket = HistoryDealGetTicket(d);
                  profit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                            HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                            HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
               }
            }
            double balance = AccountInfoDouble(ACCOUNT_BALANCE);
            double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
            string icon = (profit >= 0) ? "✅" : "⛔";
            string msg = icon + " صفقة أُغلقت\n" +
                         "الربح/الخسارة لهذه الصفقة: " + DoubleToString(profit, 2) + "$\n\n" +
                         "💰 رصيد الحساب (Balance): " + DoubleToString(balance, 2) + "$\n" +
                         "📊 الرصيد الحقيقي (Equity): " + DoubleToString(equity, 2) + "$";
            TelegramSend(msg);
         }
      }
   }

   ArrayFree(knownTickets);
   ArrayResize(knownTickets, count);
   for(int i = 0; i < count; i++) knownTickets[i] = currentTickets[i];
}

//+------------------------------------------------------------------+
//| STATISTICS REPORT (daily = 1 day back, weekly = 7 days back)      |
//+------------------------------------------------------------------+
void SendStatsReport(int daysBack)
{
   datetime from = TimeCurrent() - daysBack * 86400;
   datetime to   = TimeCurrent();

   if(!HistorySelect(from, to)) { TelegramSend("تعذر جلب السجل."); return; }

   int deals = HistoryDealsTotal();
   double totalProfit = 0;
   int wins = 0, losses = 0;

   for(int i = 0; i < deals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber) continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      double p = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                 HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                 HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      totalProfit += p;
      if(p >= 0) wins++; else losses++;
   }

   string period = (daysBack == 1) ? "📊 تقرير اليوم" : "📅 تقرير الأسبوع (آخر 7 أيام)";
   string icon = (totalProfit >= 0) ? "✅" : "⛔";
   string msg = period + "\n\n" +
                "عدد الصفقات: " + IntegerToString(wins + losses) + "\n" +
                "رابحة: " + IntegerToString(wins) + " | خاسرة: " + IntegerToString(losses) + "\n" +
                icon + " صافي الربح/الخسارة: " + DoubleToString(totalProfit, 2) + "$";
   TelegramSend(msg);
}

//+------------------------------------------------------------------+
//| NEWS: Arabic translation lookup for common event names            |
//+------------------------------------------------------------------+
string TranslateEventName(string name)
{
   string dict_en[] = {"Non-Farm", "Nonfarm", "CPI", "Interest Rate", "FOMC", "Unemployment",
                        "GDP", "PMI", "Retail Sales", "Fed Chair", "Jobless Claims",
                        "PPI", "Consumer Confidence", "Trade Balance", "Durable Goods"};
   string dict_ar[] = {"الوظائف غير الزراعية", "الوظائف غير الزراعية", "مؤشر أسعار المستهلك (التضخم)",
                        "قرار سعر الفائدة", "اجتماع الاحتياطي الفيدرالي", "معدل البطالة",
                        "الناتج المحلي الإجمالي", "مؤشر مديري المشتريات", "مبيعات التجزئة",
                        "تصريح رئيس الفيدرالي", "طلبات إعانة البطالة الأولية",
                        "مؤشر أسعار المنتجين", "ثقة المستهلك", "الميزان التجاري", "طلبيات السلع المعمرة"};

   for(int i = 0; i < ArraySize(dict_en); i++)
      if(StringFind(name, dict_en[i]) >= 0) return dict_ar[i];

   return name; // fallback to original English name if no match
}

bool AlreadyNotified(long eventId)
{
   for(int i = 0; i < ArraySize(notifiedNewsIds); i++)
      if(notifiedNewsIds[i] == eventId) return true;
   return false;
}

void MarkNotified(long eventId)
{
   int n = ArraySize(notifiedNewsIds);
   ArrayResize(notifiedNewsIds, n + 1);
   notifiedNewsIds[n] = eventId;
}

//+------------------------------------------------------------------+
//| Check upcoming high-impact USD news and alert / flag pause window |
//+------------------------------------------------------------------+
bool g_NewsPauseActive = false;

void CheckNews()
{
   // BUG FIX: previously 'from' started at now, so an event that had already
   // occurred (needed for the "pause AFTER news" window) could never be found.
   // Now we also look slightly into the past to cover NewsPauseAfterMin.
   datetime from = TimeCurrent() - (NewsPauseAfterMin * 60);
   datetime to   = TimeCurrent() + (NewsLookaheadMinutes * 60);

   MqlCalendarValue values[];
   int total = CalendarValueHistory(values, from, to, NULL, "USD");

   g_NewsPauseActive = false;

   for(int i = 0; i < total; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;
      if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      datetime eventTime = values[i].time;
      int minutesUntil = (int)((eventTime - TimeCurrent()) / 60);

      // Pause trading window around high-impact news
      if(minutesUntil <= NewsPauseBeforeMin && minutesUntil >= -NewsPauseAfterMin)
         g_NewsPauseActive = true;

      // Send alert once, when we first come within the lookahead window
      if(NotifyNews && !AlreadyNotified(values[i].event_id) && minutesUntil <= NewsLookaheadMinutes && minutesUntil > 0)
      {
         MarkNotified(values[i].event_id);
         string arName = TranslateEventName(event.name);
         string msg = "🗞 خبر اقتصادي هام قادم (يؤثر على الذهب)\n\n" +
               "الحدث: " + arName + " (" + event.name + ")\n" +
               "الوقت المتبقي: ~" + IntegerToString(minutesUntil) + " دقيقة\n" +
               "التوقع: " + DoubleToString(values[i].forecast_value, 2) + "\n" +
               "السابق: " + DoubleToString(values[i].prev_value, 2) + "\n\n" +
               "⚠️ البوت سيتوقف عن فتح صفقات جديدة من " + IntegerToString(NewsPauseBeforeMin) +
               " دقيقة قبل الخبر ولغاية " + IntegerToString(NewsPauseAfterMin) + " دقيقة بعده.";
         TelegramSend(msg);
      }
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   LoadSettings();
   g_startupEntryDone = false; // كل تشغيل جديد للـ EA = فرصة دخول فوري جديدة

   if(StringFind(_Symbol, GoldSymbolFilter) < 0)
      Print("WARNING: EA designed for Gold only. Current symbol: ", _Symbol);

   fastMA_handle = iMA(_Symbol, PERIOD_CURRENT, FastMA_Period, 0, MA_Method, PRICE_CLOSE);
   slowMA_handle = iMA(_Symbol, PERIOD_CURRENT, SlowMA_Period, 0, MA_Method, PRICE_CLOSE);
   rsi_handle    = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);

   if(fastMA_handle == INVALID_HANDLE || slowMA_handle == INVALID_HANDLE || rsi_handle == INVALID_HANDLE)
   {
      Print("Error creating indicator handles");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);

   InitKnownTickets(); // prevents false "new trade" alerts for positions already open before EA start

   EventSetTimer(PollingIntervalSec);

   // CRITICAL CHECK: averaging (multiple simultaneous trades on the same symbol)
   // only works correctly on a HEDGING account. On a NETTING account, MT5 merges
   // all trades on the same symbol into a single position, which breaks the
   // basket-counting and loss-cap logic entirely.
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      string warn = "⚠️ تحذير هام: حسابك ليس من نوع Hedging.\n" +
                    "استراتيجية التعويض (فتح عدة صفقات بنفس الاتجاه) لن تعمل بشكل صحيح "+
                    "على حساب Netting لأن المنصة ستدمج كل الصفقات بصفقة واحدة.\n" +
                    "يرجى التأكد من نوع حسابك مع الوسيط قبل الاستخدام الحقيقي.";
      Print(warn);
      TelegramSend(warn);
   }

   TelegramSend("🤖 تم تشغيل بوت الذهب بنجاح.\nالرمز: " + _Symbol + "\nالحد الأقصى للصفقات: " + IntegerToString(MaxOpenTrades));
   SendMainMenu();

   Print("Gold Telegram EA initialized.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   IndicatorRelease(fastMA_handle);
   IndicatorRelease(slowMA_handle);
   IndicatorRelease(rsi_handle);
   TelegramSend("🛑 تم إيقاف بوت الذهب.");
}

//+------------------------------------------------------------------+
//| Timer: polling Telegram + news check (lighter frequency tasks)    |
//+------------------------------------------------------------------+
datetime g_lastNewsCheck = 0;
datetime g_lastDailyReport = 0;
datetime g_lastWeeklyReport = 0;

void OnTimer()
{
   PollTelegramUpdates();

   // Check news every 60 seconds
   if(TimeCurrent() - g_lastNewsCheck >= 60)
   {
      g_lastNewsCheck = TimeCurrent();
      CheckNews();
   }

   // Auto daily report at 23:55 server time
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(NotifyDaily && dt.hour == 23 && dt.min >= 55 && TimeCurrent() - g_lastDailyReport > 3600)
   {
      g_lastDailyReport = TimeCurrent();
      SendStatsReport(1);
   }
   // Auto weekly report on Friday 23:55 server time
   if(NotifyWeekly && dt.day_of_week == 5 && dt.hour == 23 && dt.min >= 55 && TimeCurrent() - g_lastWeeklyReport > 3600)
   {
      g_lastWeeklyReport = TimeCurrent();
      SendStatsReport(7);
   }
}

//+------------------------------------------------------------------+
//| Basket / position management (same logic as previous version)     |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

double GetBasketFloatingProfit()
{
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return total;
}

long GetBasketDirection()
{
   datetime oldestTime = 0;
   long dir = -1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(oldestTime == 0 || t < oldestTime) { oldestTime = t; dir = PositionGetInteger(POSITION_TYPE); }
   }
   return dir;
}

double GetLastTradeOpenPrice()
{
   datetime newestTime = 0;
   double price = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t >= newestTime) { newestTime = t; price = PositionGetDouble(POSITION_PRICE_OPEN); }
   }
   return price;
}

void CloseAllPositions(string reason)
{
   Print("BASKET STOP TRIGGERED: ", reason);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         trade.PositionClose(ticket);
   }
   if(NotifyTrades)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      TelegramSend("⛔ تم إغلاق كل الصفقات (وقف الخسارة التراكمي)\nالسبب: " + reason + "\n\n" +
                   "💰 رصيد الحساب (Balance): " + DoubleToString(balance, 2) + "$\n" +
                   "📊 الرصيد الحقيقي (Equity): " + DoubleToString(equity, 2) + "$");
   }
}

void ManageIndividualTakeProfits()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(profit >= IndividualTP_USD) trade.PositionClose(ticket);
   }
}

void ManageBasketStop()
{
   int count = CountOpenPositions();
   if(count == 0) return;
   double floatingProfit = GetBasketFloatingProfit();
   double maxLossAllowed = LossPerTradeUSD * count;
   if(floatingProfit <= -maxLossAllowed)
      CloseAllPositions(StringFormat("خسارة $%.2f وصلت للحد الأقصى -$%.2f لـ %d صفقات", floatingProfit, maxLossAllowed, count));
}

int GetSpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (int)MathRound((ask - bid) / point);
}

//+------------------------------------------------------------------+
//| NEW: دخول فوري عند تشغيل البوت - حسب اتجاه الترند الحالي فقط،     |
//| بدون انتظار تقاطع وبدون فلتر RSI (بناءً على طلب صريح من المستخدم).|
//| يشتغل مرة وحدة بس بكل تشغيل للـ EA (أول ما count == 0).           |
//| ⚠️ هذا يرفع الخطورة لأنه يدخل بدون تأكيد إشارة حقيقية.            |
//+------------------------------------------------------------------+
void CheckImmediateEntry()
{
   double fastMA[2], slowMA[2];
   if(CopyBuffer(fastMA_handle, 0, 0, 2, fastMA) < 2) return;
   if(CopyBuffer(slowMA_handle, 0, 0, 2, slowMA) < 2) return;

   double fastCurr = fastMA[1];
   double slowCurr = slowMA[1];

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool ok;
   if(fastCurr >= slowCurr)
   {
      ok = trade.Buy(LotSize, _Symbol, ask, 0, 0, "Gold Basket Buy #1 (startup-trend)");
      Print("[STARTUP-ENTRY] فتح شراء فوري حسب الترند (بدون انتظار تقاطع/بدون RSI). fastMA=", fastCurr, " slowMA=", slowCurr);
      if(NotifyTrades)
         TelegramSend("⚡ دخول فوري عند التشغيل\nالاتجاه: 🟢 شراء (EMA السريع أعلى من البطيء)\n⚠️ هذا الدخول تجاوز شرط التقاطع وفلتر RSI بناءً على طلبك.");
   }
   else
   {
      ok = trade.Sell(LotSize, _Symbol, bid, 0, 0, "Gold Basket Sell #1 (startup-trend)");
      Print("[STARTUP-ENTRY] فتح بيع فوري حسب الترند (بدون انتظار تقاطع/بدون RSI). fastMA=", fastCurr, " slowMA=", slowCurr);
      if(NotifyTrades)
         TelegramSend("⚡ دخول فوري عند التشغيل\nالاتجاه: 🔴 بيع (EMA السريع أدنى من البطيء)\n⚠️ هذا الدخول تجاوز شرط التقاطع وفلتر RSI بناءً على طلبك.");
   }
   if(!ok) Print("Startup entry failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Entry signal - FIXED: correct index order (0=current,1=last bar)  |
//+------------------------------------------------------------------+
void CheckInitialEntry()
{
   double fastMA[3], slowMA[3], rsi[2];
   if(CopyBuffer(fastMA_handle, 0, 0, 3, fastMA) < 3) return;
   if(CopyBuffer(slowMA_handle, 0, 0, 3, slowMA) < 3) return;
   if(CopyBuffer(rsi_handle, 0, 0, 2, rsi) < 2) return;

   // index 0 = current forming bar, 1 = last closed bar, 2 = bar before that
   double fastCurr = fastMA[1], fastPrev = fastMA[2];
   double slowCurr = slowMA[1], slowPrev = slowMA[2];
   double rsiCurr  = rsi[1];

   bool bullishCross = (fastPrev <= slowPrev) && (fastCurr > slowCurr);
   bool bearishCross = (fastPrev >= slowPrev) && (fastCurr < slowCurr);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ---- DIAGNOSTIC LOG: يطبع بكل شمعة جديدة حتى لو ما دخل صفقة ----
   // شوف هذا بـ Journal / Experts tab بالمتاجر عشان تعرف ليش ما يدخل صفقات
   PrintFormat("[DIAG] fastPrev=%.2f slowPrev=%.2f fastCurr=%.2f slowCurr=%.2f RSI=%.1f | bullCross=%s bearCross=%s | spread=%d",
               fastPrev, slowPrev, fastCurr, slowCurr, rsiCurr,
               bullishCross ? "YES" : "no", bearishCross ? "YES" : "no", GetSpreadPoints());

   bool ok;
   if(bullishCross && rsiCurr < RSI_Overbought)
   {
      ok = trade.Buy(LotSize, _Symbol, ask, 0, 0, "Gold Basket Buy #1");
      if(!ok) Print("Buy failed: ", trade.ResultRetcodeDescription());
   }
   else if(bullishCross && rsiCurr >= RSI_Overbought)
   {
      PrintFormat("[DIAG] تقاطع صعودي ظهر لكن RSI=%.1f >= %.1f (تشبع شرائي) فما دخلنا", rsiCurr, RSI_Overbought);
   }
   else if(bearishCross && rsiCurr > RSI_Oversold)
   {
      ok = trade.Sell(LotSize, _Symbol, bid, 0, 0, "Gold Basket Sell #1");
      if(!ok) Print("Sell failed: ", trade.ResultRetcodeDescription());
   }
   else if(bearishCross && rsiCurr <= RSI_Oversold)
   {
      PrintFormat("[DIAG] تقاطع هبوطي ظهر لكن RSI=%.1f <= %.1f (تشبع بيعي) فما دخلنا", rsiCurr, RSI_Oversold);
   }
}

void CheckAveragingEntry()
{
   int count = CountOpenPositions();
   if(count == 0 || count >= MaxOpenTrades) return;

   long dir = GetBasketDirection();
   double lastOpenPrice = GetLastTradeOpenPrice();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool ok;
   if(dir == POSITION_TYPE_BUY && lastOpenPrice - ask >= AveragingDistancePoints * point)
   {
      ok = trade.Buy(LotSize, _Symbol, ask, 0, 0, StringFormat("Gold Basket Buy #%d (avg)", count + 1));
      if(!ok) Print("Averaging buy failed: ", trade.ResultRetcodeDescription());
   }
   else if(dir == POSITION_TYPE_SELL && bid - lastOpenPrice >= AveragingDistancePoints * point)
   {
      ok = trade.Sell(LotSize, _Symbol, bid, 0, 0, StringFormat("Gold Basket Sell #%d (avg)", count + 1));
      if(!ok) Print("Averaging sell failed: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(StringFind(_Symbol, GoldSymbolFilter) < 0) return;

   ManageBasketStop();
   ManageIndividualTakeProfits();
   CheckTradeNotifications();

   // ---- DIAGNOSTIC LOG (مرة كل 30 ثانية فقط حتى لا يغرق اللوغ) ----
   static datetime lastDiagPrint = 0;
   if(TimeCurrent() - lastDiagPrint >= 30)
   {
      lastDiagPrint = TimeCurrent();
      if(GetSpreadPoints() > MaxSpread_Points)
         PrintFormat("[DIAG] لا دخول: السبريد الحالي %d أعلى من المسموح %d", GetSpreadPoints(), MaxSpread_Points);
      if(g_NewsPauseActive)
         Print("[DIAG] لا دخول: البوت بوضع إيقاف مؤقت بسبب اقتراب/حدوث خبر هام");
   }

   if(GetSpreadPoints() > MaxSpread_Points) return;
   if(g_NewsPauseActive) return; // paused around high-impact news

   int count = CountOpenPositions();

   if(count == 0)
   {
      if(!g_startupEntryDone)
      {
         // يفتح مرة وحدة بس، أول تيك بعد تشغيل الـ EA، بغض النظر عن التقاطع
         g_startupEntryDone = true;
         CheckImmediateEntry();
      }
      else
      {
         static datetime lastBarTime = 0;
         datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
         if(currentBarTime != lastBarTime)
         {
            lastBarTime = currentBarTime;
            CheckInitialEntry();
         }
      }
   }
   else if(count < MaxOpenTrades)
   {
      CheckAveragingEntry();
   }
}
//+------------------------------------------------------------------+

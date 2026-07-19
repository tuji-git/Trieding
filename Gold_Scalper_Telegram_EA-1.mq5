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
input int      MaxOpenTrades           = 5;
input int      AveragingDistancePoints = 300;

input group "=== Profit & Basket Loss Cap ==="
input double   TP_Trade1          = 0.50;   // هدف ربح الصفقة الأولى ($)
input double   TP_Trade2          = 1.00;   // هدف ربح الصفقة الثانية ($)
input double   TP_Trade3          = 1.50;   // هدف ربح الصفقة الثالثة ($)
input double   TP_Trade4          = 2.00;   // هدف ربح الصفقة الرابعة ($)
input double   TP_Trade5          = 3.00;   // هدف ربح الصفقة الخامسة وما بعدها ($)
input double   LossPerTradeUSD     = 10.0;

input group "=== Trade Filters ==="
input int      MagicNumber         = 202608;
input int      MaxSpread_Points    = 50;

input group "=== News Settings ==="
input int      NewsLookaheadMinutes = 60;   // Alert this many minutes before high-impact news
input int      NewsPauseBeforeMin   = 15;   // Stop opening NEW trades this many minutes before news
input int      NewsPauseAfterMin    = 15;   // Resume trading this many minutes after news

input group "=== 1) Account Equity Protection ==="
input bool     UseEquityProtection    = true;   // إذا true، البوت يوقف نفسه لو خسر equity الحساب نسبة معينة
input double   MaxEquityDrawdownPercent = 20.0; // % خسارة من "أعلى قمة" وصلها الحساب (مو بس رصيد البداية) - لو تحقق ربح والحساب صعد، السقف يتحرك وياه

input group "=== 2) Dynamic Averaging Distance (ATR) ==="
input bool     UseDynamicATRDistance = true;    // إذا true، مسافة المضاعفة تتغير حسب تقلب السوق بدل رقم ثابت
input int      ATR_Period            = 14;
input double   ATR_DistanceMultiplier= 1.5;     // مسافة المضاعفة = ATR × هذا الرقم

input group "=== 3) Trend Strength Filter (Chop Filter) ==="
input bool     UseChopFilter         = true;    // يمنع الدخول لو الفرق بين المتوسطين صغير جداً (سوق عشوائي)
input double   MinTrendGapATRRatio   = 0.15;    // الفرق المطلوب بين EMA5 وEMA20 كنسبة من ATR

input group "=== 4) Basket Profit Trailing ==="
input bool     UseBasketTrailing     = true;    // يقفل جزء من ربح السلة بدل انتظار هدف ثابت بس
input double   TrailingArmProfitUSD  = 2.0;     // يبدأ التتبع لما ربح السلة العائم يوصل هذا الرقم
input double   TrailingStepUSD       = 0.5;     // لو الربح رجع هالمقدار من أعلى قمة، يسكر كل شي

input group "=== 6) Trading Session Filter ==="
input bool     UseSessionFilter      = false;   // false = يشتغل طول اليوم (كما كان)
input int      SessionStartHour      = 8;       // بتوقيت السيرفر
input int      SessionEndHour        = 22;      // بتوقيت السيرفر

input group "=== 7) اللوت المتدرج ==="
input double   MinLot            = 0.01;   // أدنى لوت (لأول صفقتين بالسلة)
input double   MaxLot            = 0.10;   // أعلى لوت (سقف ما يتجاوزه اللوت أبداً)
input int      TradesPerLotStep  = 2;      // كل كم صفقة يزيد اللوت خطوة وحدة (افتراضي: كل صفقتين)
input double   LotStepIncrement  = 0.01;   // مقدار زيادة اللوت بكل خطوة
input bool     UseIncrementalLot = true;   // false = يخلي اللوت ثابت على "أدنى لوت" لكل صفقات السلة

input group "=== 8) شبكة أمان إضافية (Safety Net Stop Loss) ==="
input bool     UseSafetyNetSL      = true;    // يحط وقف خسارة حقيقي بعيد جداً عند الوسيط (حماية لو انقطع النت/تعطل الجهاز)
input int      SafetyNetSL_Points  = 5000;    // المسافة بالنقاط - هذا احتياطي فقط، مو جزء من إدارة المخاطر الأساسية

//====================== GLOBALS ======================================
int fastMA_handle, slowMA_handle, rsi_handle, atr_handle;
string GV_PREFIX;   // unique global-variable prefix per magic number
long   lastUpdateId = 0;
long   knownTickets[];              // tracks open tickets to detect new opens/closes
long   notifiedNewsIds[];           // event ids already alerted this session

// --- ميزات جديدة (equity protection / trailing) ---
double g_startBalance   = 0;        // رصيد بداية الجلسة (للعرض فقط)
double g_peakEquity     = 0;        // أعلى equity وصلها الحساب - هذا الأساس الفعلي لحساب نسبة الخسارة
bool   g_tradingHalted  = false;    // لو true، البوت يوقف فتح صفقات جديدة نهائياً لين تعيد تشغيله
bool   g_trailingArmed  = false;
double g_trailingPeak   = 0;

// (ملاحظة: الدخول الفوري الآن مستمر عند كل إغلاق سلة، مو مرة وحدة فقط)

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
   int res = WebRequest("POST", url, headers, 5000, postData, result, resultHeaders);
   // BUG FOUND & FIXED: قبل التعديل ما كان يسجل شي لو فشل الطلب، فيصير يفشل بصمت بدون أي أثر بالـ Journal
   if(res == -1)
      Print("TelegramAnswerCallback WebRequest FAILED. Error: ", GetLastError());
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

   if(StringFind(_Symbol, GoldSymbolFilter) < 0)
      Print("WARNING: EA designed for Gold only. Current symbol: ", _Symbol);

   fastMA_handle = iMA(_Symbol, PERIOD_CURRENT, FastMA_Period, 0, MA_Method, PRICE_CLOSE);
   slowMA_handle = iMA(_Symbol, PERIOD_CURRENT, SlowMA_Period, 0, MA_Method, PRICE_CLOSE);
   rsi_handle    = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   atr_handle    = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(fastMA_handle == INVALID_HANDLE || slowMA_handle == INVALID_HANDLE || rsi_handle == INVALID_HANDLE || atr_handle == INVALID_HANDLE)
   {
      Print("Error creating indicator handles");
      return(INIT_FAILED);
   }

   g_startBalance  = AccountInfoDouble(ACCOUNT_BALANCE); // أساس حساب حماية الـ equity
   g_peakEquity    = g_startBalance;                      // القمة تبدأ من رصيد البداية وتترفع مع الأرباح
   g_tradingHalted = false;
   g_trailingArmed = false;
   g_trailingPeak  = 0;

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

   // BUG FOUND & FIXED: تحقق من إن حدود اللوت اللي حطها المستخدم ممكنة فعلياً عند الوسيط
   double brokerMinLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double brokerMaxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(MaxLot < brokerMinLot)
   {
      string warnLot = StringFormat("⚠️ تحذير خطير: 'أعلى لوت' اللي حطيته (%.2f) أقل من أدنى لوت يقبله الوسيط (%.2f).\nالبوت لن يقدر يفتح أي صفقة! رجاءً زود 'أعلى لوت'.", MaxLot, brokerMinLot);
      Print(warnLot);
      TelegramSend(warnLot);
   }
   if(MinLot > brokerMaxLot)
   {
      string warnLot2 = StringFormat("⚠️ تحذير: 'أدنى لوت' (%.2f) أكبر من أقصى لوت يقبله الوسيط (%.2f).", MinLot, brokerMaxLot);
      Print(warnLot2);
      TelegramSend(warnLot2);
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
   IndicatorRelease(atr_handle);
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
   // BUG FOUND & FIXED: كانت تستخدم ">=" فتختار آخر صفقة تتفحصها بالحلقة عند تطابق الوقت
   // تماماً (نادر بس ممكن)، صارت "الأحدث الحقيقية" فقط بـ ">"
   datetime newestTime = 0;
   double price = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t > newestTime) { newestTime = t; price = PositionGetDouble(POSITION_PRICE_OPEN); }
   }
   return price;
}

void CloseAllPositions(string reason)
{
   // BUG FOUND & FIXED: قبل التعديل، هذي الدالة ترسل رسالة "تم إغلاق كل الصفقات"
   // حتى لو ما فيه شي مفتوح أصلاً (مثلاً لو انسكرت الصفقات بدالة ثانية بنفس التيك)
   int openCount = CountOpenPositions();
   if(openCount == 0) return;

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

// يرجع هدف الربح المطلوب حسب ترتيب الصفقة داخل السلة (1=الأولى...5=الخامسة وما بعدها)
double GetTPForTradeNumber(int n)
{
   switch(n)
   {
      case 1: return TP_Trade1;
      case 2: return TP_Trade2;
      case 3: return TP_Trade3;
      case 4: return TP_Trade4;
      default: return TP_Trade5; // الخامسة وأي صفقة بعدها
   }
}

void ManageIndividualTakeProfits()
{
   // نجمع تذاكر صفقاتنا مع وقت فتحها حتى نعرف ترتيبها (الأولى/الثانية/...)
   ulong tickets[]; datetime times[];
   ArrayResize(tickets, 0); ArrayResize(times, 0);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      ArrayResize(times, n + 1);
      tickets[n] = ticket;
      times[n]   = (datetime)PositionGetInteger(POSITION_TIME);
   }

   int cnt = ArraySize(tickets);
   // ترتيب تصاعدي حسب وقت الفتح (الأقدم = صفقة رقم 1)
   for(int a = 0; a < cnt - 1; a++)
      for(int b = 0; b < cnt - 1 - a; b++)
         if(times[b] > times[b + 1])
         {
            datetime tTmp = times[b];   times[b] = times[b + 1];   times[b + 1] = tTmp;
            ulong    kTmp = tickets[b]; tickets[b] = tickets[b + 1]; tickets[b + 1] = kTmp;
         }

   for(int idx = 0; idx < cnt; idx++)
   {
      if(!PositionSelectByTicket(tickets[idx])) continue;
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double target = GetTPForTradeNumber(idx + 1);
      if(profit >= target)
         trade.PositionClose(tickets[idx]);
   }
}

// BUG FOUND & FIXED: سقف الخسارة كان يتحسب بـ (عدد الصفقات × LossPerTradeUSD) فقط،
// بدون ما يراعي إن الصفقات المتأخرة بالسلة لوتها أكبر (بسبب اللوت المتدرج).
// يعني لو صفقة 5 لوتها 0.03 (3 أضعاف صفقة 1)، خسارتها الفعلية بالنقطة الوحدة أكبر بـ3 مرات،
// وسقف الخسارة القديم ما كان يعكس هذا الفرق. الحل: نحسب "وزن" كل صفقة نسبة للوت الأدنى.
double GetBasketWeightedCount()
{
   double weighted = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(MinLot > 0) weighted += vol / MinLot;
   }
   return weighted;
}

void ManageBasketStop()
{
   int count = CountOpenPositions();
   if(count == 0) return;
   double floatingProfit = GetBasketFloatingProfit();
   double weightedCount = GetBasketWeightedCount();
   double maxLossAllowed = LossPerTradeUSD * weightedCount;
   if(floatingProfit <= -maxLossAllowed)
      CloseAllPositions(StringFormat("خسارة $%.2f وصلت للحد الأقصى -$%.2f لـ %d صفقات (بوزن لوت %.2f)", floatingProfit, maxLossAllowed, count, weightedCount));
}

int GetSpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (int)MathRound((ask - bid) / point);
}

//+------------------------------------------------------------------+
//| 1) حماية Equity كامل الحساب - يوقف كل شي نهائياً لو الخسارة زادت  |
//+------------------------------------------------------------------+
bool CheckEquityProtection()
{
   if(!UseEquityProtection || g_tradingHalted) return g_tradingHalted;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity) g_peakEquity = equity; // يحدث القمة كل ما الحساب يحقق رقم أعلى (أرباح جديدة)
   if(g_peakEquity <= 0) return false;

   double drawdownPercent = (g_peakEquity - equity) / g_peakEquity * 100.0;

   if(drawdownPercent >= MaxEquityDrawdownPercent)
   {
      CloseAllPositions(StringFormat("حماية Equity: خسارة %.1f%% من أعلى قمة $%.2f (equity الحالي $%.2f)", drawdownPercent, g_peakEquity, equity));
      g_tradingHalted = true;
      TelegramSend("🛑 تم إيقاف البوت نهائياً عن فتح صفقات جديدة (حماية Equity من أعلى قمة).\nلازم تعيد تشغيل الـ EA يدوياً بعد ما تراجع الحساب.");
   }
   return g_tradingHalted;
}

//+------------------------------------------------------------------+
//| 2) مسافة المضاعفة الديناميكية حسب ATR                              |
//+------------------------------------------------------------------+
double GetAveragingDistancePoints()
{
   if(!UseDynamicATRDistance) return AveragingDistancePoints; // fallback للرقم الثابت

   double atrBuf[2];
   if(CopyBuffer(atr_handle, 0, 0, 2, atrBuf) < 2) return AveragingDistancePoints;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double atrPoints = atrBuf[1] / point;
   double dynamicDistance = atrPoints * ATR_DistanceMultiplier;

   // لا تخليها أقل من نص القيمة الثابتة، حماية من ATR منخفض جداً بلحظات هدوء غير طبيعي
   if(dynamicDistance < AveragingDistancePoints * 0.5)
      dynamicDistance = AveragingDistancePoints * 0.5;

   return dynamicDistance;
}

//+------------------------------------------------------------------+
//| 3) فلتر قوة الترند - يمنع الدخول بسوق عشوائي بدون اتجاه واضح       |
//+------------------------------------------------------------------+
bool IsTrendStrongEnough(double fastCurr, double slowCurr)
{
   if(!UseChopFilter) return true;

   double atrBuf[2];
   if(CopyBuffer(atr_handle, 0, 0, 2, atrBuf) < 2) return true; // ما نگدر نتحقق، نخلي يمر

   double gap = MathAbs(fastCurr - slowCurr);
   double minGap = atrBuf[1] * MinTrendGapATRRatio;
   return (gap >= minGap);
}

//+------------------------------------------------------------------+
//| 6) فلتر جلسة التداول (بتوقيت السيرفر)                              |
//+------------------------------------------------------------------+
bool IsWithinTradingSession()
{
   if(!UseSessionFilter) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(SessionStartHour <= SessionEndHour)
      return (dt.hour >= SessionStartHour && dt.hour < SessionEndHour);
   else // جلسة تعبر منتصف الليل مثلاً 22 -> 6
      return (dt.hour >= SessionStartHour || dt.hour < SessionEndHour);
}

//+------------------------------------------------------------------+
//| 7) اللوت التدريجي المحافظ - زيادة حسابية بسيطة، مو مضاعفة كاملة    |
//+------------------------------------------------------------------+
// BUG FOUND & FIXED: هذي الدالة قبل التعديل كانت تستخدم MathRound (تقريب لأقرب رقم)
// بعد فرض سقف "أعلى لوت" مباشرة - وهذا ممكن يرجع اللوت يتجاوز السقف نفسه!
// مثال: أعلى لوت = 0.015 وخطوة الوسيط 0.01 => MathRound(1.5)=2 => لوت نهائي 0.02 (تجاوز السقف).
// الحل: نستخدم MathFloor (تقريب للأسفل دائماً) حتى نضمن عدم تجاوز أي سقف مهما كانت القيم.
// شبكة أمان: وقف خسارة حقيقي بعيد جداً عند الوسيط، طبقة حماية إضافية لو النت/الجهاز تعطل
double CalcSafetyNetSL(bool isBuy, double price)
{
   if(!UseSafetyNetSL) return 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double dist  = SafetyNetSL_Points * point;
   return isBuy ? price - dist : price + dist;
}

double ClampLotToBrokerLimits(double lot)
{
   double minBroker = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxBroker = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;

   lot = MathFloor(lot / step + 0.0000001) * step; // تقريب للأسفل فقط، أبداً لا يتجاوز السقف

   if(lot < minBroker) lot = minBroker; // حد الوسيط الأدنى (لا مفر منه، الوسيط ما يقبل أقل)
   if(lot > maxBroker) lot = maxBroker;
   return lot;
}

double LotForTradeNumber(int n)
{
   double lot;
   if(!UseIncrementalLot || n <= 0 || TradesPerLotStep <= 0)
      lot = MinLot;
   else
   {
      int stepIndex = (n - 1) / TradesPerLotStep;   // 0 لأول مجموعة صفقات، 1 للمجموعة الثانية...
      lot = MinLot + stepIndex * LotStepIncrement;
   }

   if(lot > MaxLot) lot = MaxLot; // سقف المستخدم أولاً، قبل أي تقريب

   return ClampLotToBrokerLimits(lot);
}

//+------------------------------------------------------------------+
//| 4) Trailing على ربح السلة بالكامل - يقفل جزء من الربح بدل الانتظار |
//+------------------------------------------------------------------+
void ManageBasketTrailing()
{
   int count = CountOpenPositions();
   if(count == 0)
   {
      g_trailingArmed = false;
      g_trailingPeak  = 0;
      return;
   }
   if(!UseBasketTrailing) return;

   double floatingProfit = GetBasketFloatingProfit();

   if(!g_trailingArmed)
   {
      if(floatingProfit >= TrailingArmProfitUSD)
      {
         g_trailingArmed = true;
         g_trailingPeak  = floatingProfit;
      }
      return;
   }

   if(floatingProfit > g_trailingPeak) g_trailingPeak = floatingProfit;

   if(g_trailingPeak - floatingProfit >= TrailingStepUSD)
      CloseAllPositions(StringFormat("Trailing: قفل ربح عند $%.2f بعد قمة $%.2f", floatingProfit, g_trailingPeak));
}

//+------------------------------------------------------------------+
//| NEW: دخول فوري عند تشغيل البوت - حسب اتجاه الترند الحالي فقط،     |
//| بدون انتظار تقاطع وبدون فلتر RSI (بناءً على طلب صريح من المستخدم).|
//| يشتغل مرة وحدة بس بكل تشغيل للـ EA (أول ما count == 0).           |
//| ⚠️ هذا يرفع الخطورة لأنه يدخل بدون تأكيد إشارة حقيقية.            |
//+------------------------------------------------------------------+
void CheckImmediateEntry()
{
   if(!IsWithinTradingSession()) return; // خارج ساعات الجلسة المسموحة

   double fastMA[2], slowMA[2];
   if(CopyBuffer(fastMA_handle, 0, 0, 2, fastMA) < 2) return;
   if(CopyBuffer(slowMA_handle, 0, 0, 2, slowMA) < 2) return;

   double fastCurr = fastMA[1];
   double slowCurr = slowMA[1];

   if(!IsTrendStrongEnough(fastCurr, slowCurr))
   {
      Print("[DIAG] لا دخول فوري: الفرق بين المتوسطين صغير جداً مقارنة بـ ATR (سوق متذبذب)");
      return;
   }

   double lot = LotForTradeNumber(1);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool ok;
   if(fastCurr >= slowCurr)
   {
      double sl = CalcSafetyNetSL(true, ask);
      ok = trade.Buy(lot, _Symbol, ask, sl, 0, "Gold Basket Buy #1 (startup-trend)");
      Print("[STARTUP-ENTRY] فتح شراء فوري حسب الترند. lot=", lot, " fastMA=", fastCurr, " slowMA=", slowCurr);
      if(NotifyTrades)
         TelegramSend("⚡ دخول فوري (لوت " + DoubleToString(lot,2) + ")\nالاتجاه: 🟢 شراء (EMA السريع أعلى من البطيء)");
   }
   else
   {
      double sl = CalcSafetyNetSL(false, bid);
      ok = trade.Sell(lot, _Symbol, bid, sl, 0, "Gold Basket Sell #1 (startup-trend)");
      Print("[STARTUP-ENTRY] فتح بيع فوري حسب الترند. lot=", lot, " fastMA=", fastCurr, " slowMA=", slowCurr);
      if(NotifyTrades)
         TelegramSend("⚡ دخول فوري (لوت " + DoubleToString(lot,2) + ")\nالاتجاه: 🔴 بيع (EMA السريع أدنى من البطيء)");
   }
   if(!ok) Print("Startup entry failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Entry signal - FIXED: correct index order (0=current,1=last bar)  |
//+------------------------------------------------------------------+
void CheckInitialEntry()
{
   if(!IsWithinTradingSession()) return; // خارج ساعات الجلسة المسموحة

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

   if((bullishCross || bearishCross) && !IsTrendStrongEnough(fastCurr, slowCurr))
   {
      Print("[DIAG] تقاطع صار بس الفرق صغير جداً مقارنة بـ ATR (فلتر التذبذب رفضه)");
      return;
   }

   double lot = LotForTradeNumber(1);
   bool ok;
   if(bullishCross && rsiCurr < RSI_Overbought)
   {
      double sl = CalcSafetyNetSL(true, ask);
      ok = trade.Buy(lot, _Symbol, ask, sl, 0, "Gold Basket Buy #1");
      if(!ok) Print("Buy failed: ", trade.ResultRetcodeDescription());
   }
   else if(bullishCross && rsiCurr >= RSI_Overbought)
   {
      PrintFormat("[DIAG] تقاطع صعودي ظهر لكن RSI=%.1f >= %.1f (تشبع شرائي) فما دخلنا", rsiCurr, RSI_Overbought);
   }
   else if(bearishCross && rsiCurr > RSI_Oversold)
   {
      double sl = CalcSafetyNetSL(false, bid);
      ok = trade.Sell(lot, _Symbol, bid, sl, 0, "Gold Basket Sell #1");
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
   double distancePoints = GetAveragingDistancePoints(); // ثابت أو ديناميكي حسب ATR
   double lot = LotForTradeNumber(count + 1);

   bool ok;
   if(dir == POSITION_TYPE_BUY && lastOpenPrice - ask >= distancePoints * point)
   {
      double sl = CalcSafetyNetSL(true, ask);
      ok = trade.Buy(lot, _Symbol, ask, sl, 0, StringFormat("Gold Basket Buy #%d (avg)", count + 1));
      if(!ok) Print("Averaging buy failed: ", trade.ResultRetcodeDescription());
   }
   else if(dir == POSITION_TYPE_SELL && bid - lastOpenPrice >= distancePoints * point)
   {
      double sl = CalcSafetyNetSL(false, bid);
      ok = trade.Sell(lot, _Symbol, bid, sl, 0, StringFormat("Gold Basket Sell #%d (avg)", count + 1));
      if(!ok) Print("Averaging sell failed: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(StringFind(_Symbol, GoldSymbolFilter) < 0) return;

   ManageBasketStop();
   ManageIndividualTakeProfits();
   ManageBasketTrailing();
   CheckTradeNotifications();

   // 1) حماية Equity - لو انفعلت، البوت يوقف نهائياً عن فتح صفقات جديدة
   if(CheckEquityProtection()) return;

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
      // رجعنا لنظام التقاطع: ما يدخل إلا لما يصير تقاطع حقيقي بين EMA5 وEMA20
      // على شمعة مقفلة (مو دخول فوري تلقائي بغض النظر عن الإشارة)
      static datetime lastBarTime = 0;
      datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(currentBarTime != lastBarTime)
      {
         lastBarTime = currentBarTime;
         CheckInitialEntry();
      }
   }
   else if(count < MaxOpenTrades)
   {
      CheckAveragingEntry();
   }
}
//+------------------------------------------------------------------+

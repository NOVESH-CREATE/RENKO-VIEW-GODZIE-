print("=== IMPORTING MODULES ===")
import MetaTrader5 as mt5
import pandas as pd
import numpy as np
from dash import Dash, html, dcc, callback, Output, Input
import plotly.graph_objects as go
from datetime import datetime, timedelta
print("=== MODULES IMPORTED ===", flush=True)

if not mt5.initialize():
    print("MT5 initialize failed")
    print("Error:", mt5.last_error())
    mt5.shutdown()
    exit(1)
else:
    print("MT5 initialized successfully")
    account_info = mt5.account_info()
    if account_info:
        print(f"Account: {account_info.login}, Server: {account_info.server}")
    else:
        print("Failed to get account info")

def get_renko_bricks(symbol, timeframe, box_size, num_bricks=140):
    """Get Renko bricks that match Pine script logic with minute-based confirmation"""
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, 1000)
    if rates is None:
        return None, None
    
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    
    if len(df) == 0:
        return None, None
    
    # Initialize like Pine script: start with first close price adjusted to box boundary
    first_close = df['close'].iloc[0]
    close_level = np.floor(first_close / box_size) * box_size
    
    # Arrays to store ALL brick data (matching Pine's rclose array behavior)
    all_brick_closes = [close_level]  # Close price of each brick
    all_brick_opens = [close_level]   # Open price of each brick
    all_brick_highs = [close_level]   # High price of each brick
    all_brick_lows = [close_level]    # Low price of each brick
    all_brick_times = [df['time'].iloc[0]]  # Time of each brick
    all_brick_trends = [0]            # Trend of each brick (0=no trend, 1=up, -1=down)
    
    # Track which MT5 candle each brick came from for minute-based confirmation
    brick_source_candle_idx = [0]     # Index in df of the candle that contributed to this brick
    
    total_bricks = 0  # Total number of bricks created (for numbering)
    current_trend = 0 # Current trend (0=no trend, 1=up, -1=down)
    
    # Process each price bar (MT5 candle) - ALL data including currently forming
    for i in range(len(df)):
        current_price = df['close'].iloc[i]
        current_time = df['time'].iloc[i]
        
        # Skip the first iteration since we already initialized with candle 0's close
        if i == 0 and len(all_brick_closes) == 1 and all_brick_closes[0] == close_level:
            # We already initialized with this candle's data, skip to avoid double counting
            continue
            
        last_close = all_brick_closes[-1]  # Most recent brick close
        numcell = int(abs(last_close - current_price) / box_size)
        
        if numcell > 0:
            if current_trend == 0:
                # No established trend yet, need at least 2 boxes to establish trend
                if numcell >= 2:
                    # Establish trend: 1 if price is going up, -1 if going down
                    current_trend = 1 if current_price > last_close else -1
                    
                    # Add numcell bricks
                    for _ in range(numcell):
                        brick_open = last_close
                        last_close += current_trend * box_size
                        brick_close = last_close
                        
                        all_brick_opens.append(brick_open)
                        all_brick_closes.append(brick_close)
                        all_brick_highs.append(max(brick_open, brick_close))
                        all_brick_lows.append(min(brick_open, brick_close))
                        all_brick_times.append(current_time)
                        all_brick_trends.append(current_trend)
                        brick_source_candle_idx.append(i)  # This brick came from candle i
                        
                        total_bricks += 1
            else:
                # We have an established trend
                if last_close * current_trend < current_price * current_trend:
                    # Price is still moving in the same direction as the trend
                    # Add numcell bricks
                    for _ in range(numcell):
                        brick_open = last_close
                        last_close += current_trend * box_size
                        brick_close = last_close
                        
                        all_brick_opens.append(brick_open)
                        all_brick_closes.append(brick_close)
                        all_brick_highs.append(max(brick_open, brick_close))
                        all_brick_lows.append(min(brick_open, brick_close))
                        all_brick_times.append(current_time)
                        all_brick_trends.append(current_trend)
                        brick_source_candle_idx.append(i)  # This brick came from candle i
                        
                        total_bricks += 1
                elif numcell >= 2:
                    # Price has reversed by at least 2 box sizes, change trend
                    current_trend *= -1
                    
                    # Start from one box size in the new trend direction from last_close
                    last_close += current_trend * box_size
                    
                    # Add numcell-1 bricks (we already moved one box size above)
                    for _ in range(numcell - 1):
                        brick_open = last_close
                        last_close += current_trend * box_size
                        brick_close = last_close
                        
                        all_brick_opens.append(brick_open)
                        all_brick_closes.append(brick_close)
                        all_brick_highs.append(max(brick_open, brick_close))
                        all_brick_lows.append(min(brick_open, brick_close))
                        all_brick_times.append(current_time)
                        all_brick_trends.append(current_trend)
                        brick_source_candle_idx.append(i)  # This brick came from candle i
                        
                        total_bricks += 1
    
    # NOW APPLY MINUTE-BASED CONFIRMATION LOGIC
    # A brick is CONFIRMED only if it came from a completed minute candle
    # A brick is UNCONFIRMED if it came from the currently forming minute candle
    
    now = datetime.now()
    current_minute_start = now.replace(second=0, microsecond=0)
    
    confirmed_bricks = []
    unconfirmed_bricks = []  # Can contain MULTIPLE bricks from current minute
    
    # Skip the initial placeholder (index 0) which was just our starting point
    start_idx = 1
    
    for i in range(start_idx, len(all_brick_closes)):
        # Get the source candle index for this brick
        source_candle_idx = brick_source_candle_idx[i]
        source_candle_time = df['time'].iloc[source_candle_idx]
        
        brick_data = {
            'brick_num': total_bricks - len(all_brick_closes) + i,  # Sequential numbering
            'open': all_brick_opens[i],
            'close': all_brick_closes[i],
            'high': all_brick_highs[i],
            'low': all_brick_lows[i],
            'time': all_brick_times[i],
            'trend': all_brick_trends[i],
            'source_candle_time': source_candle_time,
            'source_candle_idx': source_candle_idx
        }
        
        # CONFIRMATION LOGIC: Brick is confirmed only if source candle is COMPLETED
        # A candle is completed if its time is BEFORE the start of current minute
        if source_candle_time < current_minute_start:
            # This brick came from a completed minute - CONFIRMED
            brick_data['confirmed'] = True
            confirmed_bricks.append(brick_data)
        else:
            # This brick came from the current forming minute - UNCONFIRMED
            brick_data['confirmed'] = False
            unconfirmed_bricks.append(brick_data)
    
    # Keep only the most recent bricks for performance
    # Combine confirmed and unconfirmed for display, then split back
    all_bricks_for_display = confirmed_bricks + unconfirmed_bricks
    if len(all_bricks_for_display) > num_bricks:
        all_bricks_for_display = all_bricks_for_display[-num_bricks:]
        # Renumber the bricks to be sequential for display
        for i, brick in enumerate(all_bricks_for_display):
            brick['brick_num'] = i
        
        # Split back into confirmed and unconfirmed
        confirmed_bricks = [b for b in all_bricks_for_display if b['confirmed']]
        unconfirmed_bricks = [b for b in all_bricks_for_display if not b['confirmed']]
    
    # Return confirmed bricks as DataFrame (for EMA) and unconfirmed as list (for display)
    confirmed_df = pd.DataFrame(confirmed_bricks) if confirmed_bricks else pd.DataFrame()
    return confirmed_df, unconfirmed_bricks

def calculate_ema(close_prices, period=9):
    """Calculate EMA on confirmed close prices only"""
    if len(close_prices) < period:
        return []
    
    ema_values = []
    multiplier = 2 / (period + 1)
    
    first_ema = sum(close_prices[:period]) / period
    ema_values.append(first_ema)
    
    for i in range(period, len(close_prices)):
        ema = (close_prices[i] - ema_values[-1]) * multiplier + ema_values[-1]
        ema_values.append(ema)
    
    return ema_values

app = Dash(__name__)

app.layout = html.Div([
    html.H1("Renko Charts from MT5", style={'textAlign': 'center'}),
    
    html.Div([
        html.Label("Symbol:"),
        dcc.Dropdown(
            id='symbol-select',
            options=[
                {'label': 'BTCUSD', 'value': 'BTCUSD'},
                {'label': 'EURUSD', 'value': 'EURUSD'},
                {'label': 'GBPUSD', 'value': 'GBPUSD'},
                {'label': 'XAUUSD', 'value': 'XAUUSD'},
            ],
            value='BTCUSD'
        ),
        
        html.Label("Timeframe:"),
        dcc.Dropdown(
            id='tf-select',
            options=[
                {'label': '1 Minute', 'value': mt5.TIMEFRAME_M1},
                {'label': '5 Minutes', 'value': mt5.TIMEFRAME_M5},
                {'label': '15 Minutes', 'value': mt5.TIMEFRAME_M15},
                {'label': '1 Hour', 'value': mt5.TIMEFRAME_H1},
                {'label': '4 Hours', 'value': mt5.TIMEFRAME_H4},
                {'label': '1 Day', 'value': mt5.TIMEFRAME_D1},
            ],
            value=mt5.TIMEFRAME_M1
        ),
        
        html.Label("Brick Size ($):"),
        dcc.Input(id='box-size', type='number', value=5, step=0.1),
        
        html.Label("Number of Bricks:"),
        dcc.Input(id='num-bricks', type='number', value=140, step=10),
        
        html.Div(id='last-update', style={'marginTop': '10px', 'fontSize': '12px'}),
    ], style={'width': '300px', 'display': 'inline-block', 'verticalAlign': 'top', 'padding': '20px'}),
    
    dcc.Interval(id='interval-component', interval=5000, n_intervals=0),
    
    dcc.Graph(id='renko-chart'),
    
    html.Div(id='brick-data', style={'marginTop': '20px'})
])

@callback(
    [Output('renko-chart', 'figure'),
     Output('brick-data', 'children'),
     Output('last-update', 'children')],
    [Input('symbol-select', 'value'),
     Input('tf-select', 'value'),
     Input('box-size', 'value'),
     Input('num-bricks', 'value'),
     Input('interval-component', 'n_intervals')]
)
def update_chart(symbol, timeframe, box_size, num_bricks, n_intervals):
    bricks_df, unconfirmed_list = get_renko_bricks(symbol, timeframe, box_size, num_bricks)
    
    if bricks_df is None or (len(bricks_df) == 0 and len(unconfirmed_list) == 0):
        return go.Figure(), "No data available", ""
    
    # Separate truly confirmed bricks (before current minute) for EMA calculation
    now = datetime.now()
    current_minute_start = now.replace(second=0, microsecond=0)
    
    truly_confirmed_bricks = bricks_df[bricks_df['time'] < current_minute_start].copy() if len(bricks_df) > 0 else pd.DataFrame()
    current_minute_bricks = bricks_df[bricks_df['time'] >= current_minute_start].copy() if len(bricks_df) > 0 else pd.DataFrame()
    
    # Calculate EMA only on truly confirmed bricks (before current minute)
    if len(truly_confirmed_bricks) > 0:
        close_prices_for_ema = truly_confirmed_bricks['close'].tolist()
        ema_values = calculate_ema(close_prices_for_ema, period=9)
    else:
        ema_values = []
    
    fig = go.Figure()
    
    # Add truly confirmed bricks (ONLY these are visible and used for EMA)
    if len(truly_confirmed_bricks) > 0:
        fig.add_trace(go.Candlestick(
            x=[i for i in range(len(truly_confirmed_bricks))],
            open=truly_confirmed_bricks['open'].values,
            high=truly_confirmed_bricks['high'].values,
            low=truly_confirmed_bricks['low'].values,
            close=truly_confirmed_bricks['close'].values,
            increasing_line_color='green',
            decreasing_line_color='red',
            name='Confirmed Bricks',
            whiskerwidth=1
        ))
    
    # Add current minute bricks (formed in this minute - VISIBLE but not for EMA)
    if len(current_minute_bricks) > 0:
        fig.add_trace(go.Candlestick(
            x=[i + len(truly_confirmed_bricks) for i in range(len(current_minute_bricks))],
            open=current_minute_bricks['open'].values,
            high=current_minute_bricks['high'].values,
            low=current_minute_bricks['low'].values,
            close=current_minute_bricks['close'].values,
            increasing_line_color='rgba(128, 128, 128, 0.5)',  # Gray with 50% opacity
            decreasing_line_color='rgba(128, 128, 128, 0.5)', # Gray with 50% opacity
            name='Current Minute Bricks',
            increasing_fillcolor='rgba(128, 128, 128, 0.2)',
            decreasing_fillcolor='rgba(128, 128, 128, 0.2)',
            line=dict(width=1)
        ))
    
    # Add the currently forming unconfirmed brick (the very latest forming brick - VISIBLE but not for EMA)
    if unconfirmed_list is not None and len(unconfirmed_list) > 0:
        # Show ALL unconfirmed bricks from current minute (the formation process)
        for i, brick in enumerate(unconfirmed_list):
            fig.add_trace(go.Candlestick(
                x=[len(truly_confirmed_bricks) + len(current_minute_bricks) + i],
                open=[brick['open']],
                high=[brick['high']],
                low=[brick['low']],
                close=[brick['close']],
                increasing_line_color='rgba(128, 128, 128, 0.5)',  # Gray with 50% opacity
                decreasing_line_color='rgba(128, 128, 128, 0.5)', # Gray with 50% opacity
                name=f'Unconfirmed Brick {i}' if i > 0 else 'Unconfirmed',
                increasing_fillcolor='rgba(128, 128, 128, 0.2)',
                decreasing_fillcolor='rgba(128, 128, 128, 0.2)',
                line=dict(width=1),
                showlegend=(i == 0)  # Only show legend for first unconfirmed brick to avoid clutter
            ))
    
    # Calculate EMA aligned with truly confirmed bricks for plotting
    if len(ema_values) > 0:
        # EMA[0] corresponds to the 9th confirmed close price (index 8)
        # So for confirmed brick i, EMA value is ema_values[i-8] when i >= 8
        ema_x = []
        ema_y = []
        for i in range(len(truly_confirmed_bricks)):
            if i >= 8:  # Start from the 9th element (index 8)
                ema_idx = i - 8
                if ema_idx < len(ema_values):
                    ema_x.append(i)
                    ema_y.append(ema_values[ema_idx])
        
        if ema_x and ema_y:
            fig.add_trace(go.Scatter(
                x=ema_x,
                y=ema_y,
                mode='lines',
                name='EMA 9',
                line=dict(color='orange', width=2)
            ))
    
    # Calculate price range for y-axis (from all visible bricks)
    price_min = float('inf')
    price_max = float('-inf')
    
    if len(truly_confirmed_bricks) > 0:
        price_min = min(price_min, truly_confirmed_bricks['low'].min())
        price_max = max(price_max, truly_confirmed_bricks['high'].max())
    
    if len(current_minute_bricks) > 0:
        price_min = min(price_min, current_minute_bricks['low'].min())
        price_max = max(price_max, current_minute_bricks['high'].max())
    
    if unconfirmed_list is not None and len(unconfirmed_list) > 0:
        unconfirmed_lows = [brick['low'] for brick in unconfirmed_list]
        unconfirmed_highs = [brick['high'] for brick in unconfirmed_list]
        price_min = min(price_min, min(unconfirmed_lows))
        price_max = max(price_max, max(unconfirmed_highs))
    
    # Handle edge case where no data
    if price_min == float('inf'):
        price_min = 0
    if price_max == float('-inf'):
        price_max = 1
    
    # Format prices to exactly 2 decimal places as requested
    fig.update_layout(
        title=f"Renko Chart - {symbol} (Box Size: ${box_size})",
        yaxis_title="Price",
        xaxis_title="Brick Number",
        height=600,
        xaxis=dict(showticklabels=False, showgrid=False, zeroline=False),  # Hidden X-axis as requested
        yaxis=dict(
            tickformat='.2f',  # Exactly 2 decimal places
            range=[price_min - box_size, price_max + box_size]
        ),
        margin=dict(l=50, r=50, t=50, b=50)
    )
    
    # Prepare display dataframe - show ALL bricks (confirmed + current minute + unconfirmed)
    # but mark their confirmation status correctly for the table
    display_parts = []
    if len(truly_confirmed_bricks) > 0:
        display_parts.append(truly_confirmed_bricks)
    if len(current_minute_bricks) > 0:
        display_parts.append(current_minute_bricks)  # Already have correct confirmed status
    if unconfirmed_list is not None and len(unconfirmed_list) > 0:
        unconfirmed_df = pd.DataFrame(unconfirmed_list)
        display_parts.append(unconfirmed_df)
    
    if len(display_parts) > 0:
        display_df = pd.concat(display_parts, ignore_index=True)
    else:
        display_df = pd.DataFrame()
    
    price_format = '.2f'  # Always 2 decimal places as requested
    
    table_rows = []
    for _, row in display_df.tail(20).iterrows():
        brick_num = int(row['brick_num'])
        ema_val = "-"
        if row['confirmed'] and len(ema_values) > 0:
            # EMA[0] corresponds to the close price at index (period-1) in close_prices_for_ema
            # So for brick_num, we need EMA[brick_num - (period-1)] if brick_num >= (period-1)
            ema_idx = brick_num - (9 - 1)  # period is 9
            if 0 <= ema_idx < len(ema_values):
                ema_val = f"{ema_values[ema_idx]:{price_format}}"
        
        table_rows.append(html.Tr([
            html.Td(str(brick_num)),
            html.Td(f"{row['open']:{price_format}}"),
            html.Td(f"{row['close']:{price_format}}"),
            html.Td(f"{row['high']:{price_format}}"),
            html.Td(f"{row['low']:{price_format}}"),
            html.Td("Unconfirmed" if not row['confirmed'] else "Confirmed"),
            html.Td(ema_val)
        ]))
    
    table = html.Table([
        html.Tr([html.Th("Brick #"), html.Th("Open"), html.Th("Close"), html.Th("High"), html.Th("Low"), html.Th("Status"), html.Th("EMA")])
    ] + table_rows)
    
    current_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    last_update = f"Last Update: {current_time}"
    
    return fig, table, last_update

print("Starting the application...")
if __name__ == '__main__':
    app.run(debug=False, port=8050, host='127.0.0.1')
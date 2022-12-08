import numpy as np 

def predict (x,w,b):
    return x * w + b 
def loss(x,y,w,b):
    return np.average((predict(x,w,b) - y) ** 2)
def gradient (x,y,w,b):
    w_gradient = 2 * np.average(x * (predict(x,w,b) - y ))
    b_gradient = 2 * np.average(predict(x,w,b) - y )
    return (w_gradient,b_gradient)
def train(x,y,iteration

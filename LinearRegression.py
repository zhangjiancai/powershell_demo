import numpy as np

def predict(x,W)
    return x * W
def loss(x,y,W)
    return np.average( ( predict( x , W ) - y ) ** 2 ) 
def train(x,y,iterations,lr):
    W = 0
    for i in range(iterations):
        current_loss = loss( x , y , W )
        print("interation%4d => Loss:%.6f"%(i,current_loss))
        
        if loss( x , y ,W + lr ) < current_loss:
            W += lr
        elif loss( x , y , W - lr ) < current_loss:
            W -= lr 
        else:
            return W
    raise Exception("coulsn`t converage within %d iterations"% interations)

x,y = np.loadtxt("pizza.txt" , skiprows = 1 , unpack = True )

W = train( x , y ,iterations = 10000 , lr = 0.01 )
print("\nw = %.3f" %W)

